#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
version=v5.0.2
arches=(amd64 i386 aarch64 armv7l)

# Keep the payload intact: only the stored CRC fields are corrupted.
python3 - "$tmp" "$version" <<'PY'
import pathlib
import shutil
import struct
import sys
import zipfile
import zlib

root = pathlib.Path(sys.argv[1])
version = sys.argv[2]
arches = ("amd64", "i386", "aarch64", "armv7l")
payload = pathlib.Path("/bin/true").read_bytes()
actual_crc = zlib.crc32(payload)
assert payload.startswith(b"\x7fELF")

for variant in ("valid", "existing"):
    directory = root / variant
    directory.mkdir()
    for arch in arches:
        info = zipfile.ZipInfo("snell-server")
        info.compress_type = zipfile.ZIP_STORED
        info.create_system = 3
        info.external_attr = 0o100755 << 16
        path = directory / f"snell-server-{version}-linux-{arch}.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(info, payload)
            if variant == "existing":
                archive.comment = b"existing archive must remain unchanged"

for damaged_arch in (*arches, "all"):
    directory = root / f"bad-{damaged_arch}"
    shutil.copytree(root / "valid", directory)
    for arch in arches:
        if damaged_arch not in (arch, "all"):
            continue
        path = directory / f"snell-server-{version}-linux-{arch}.zip"
        data = bytearray(path.read_bytes())
        central_offset = data.index(b"PK\x01\x02")
        assert data[:4] == b"PK\x03\x04"
        assert struct.unpack_from("<I", data, 14)[0] == actual_crc
        assert struct.unpack_from("<I", data, central_offset + 16)[0] == actual_crc
        struct.pack_into("<I", data, 14, actual_crc ^ 1)
        struct.pack_into("<I", data, central_offset + 16, actual_crc ^ 1)
        path.write_bytes(data)

shutil.copytree(root / "valid", root / "missing")
(root / "missing" / f"snell-server-{version}-linux-armv7l.zip").unlink()
(root / "releases.md").write_text(f"snell-server-{version}-linux-amd64.zip\n")
PY

# Validate real ELF headers before substituting the architecture fields.
READELF_BIN=$(command -v readelf)
export READELF_BIN
readelf() {
    "$READELF_BIN" "$@" >/dev/null || return 1
    case "$*" in
        *extract-amd64*) printf '  Class: ELF64\n  Machine: Advanced Micro Devices X86-64\n' ;;
        *extract-i386*) printf '  Class: ELF32\n  Machine: Intel 80386\n' ;;
        *extract-aarch64*) printf '  Class: ELF64\n  Machine: AArch64\n' ;;
        *extract-armv7l*) printf '  Class: ELF32\n  Machine: ARM\n' ;;
        *) return 1 ;;
    esac
}
export -f readelf

for arch in "${arches[@]}"; do
    archive="$tmp/bad-all/snell-server-${version}-linux-${arch}.zip"
    if unzip -tq "$archive" >"$tmp/crc.log" 2>&1; then
        echo "CRC fixture unexpectedly passed unzip -tq: $arch" >&2
        exit 1
    fi
    grep -Fq 'bad CRC' "$tmp/crc.log"
    mkdir -p "$tmp/extracted-$arch"
    if unzip -q "$archive" -d "$tmp/extracted-$arch" >"$tmp/extract.log" 2>&1; then
        echo "CRC fixture unexpectedly extracted successfully: $arch" >&2
        exit 1
    fi
    [[ -x "$tmp/extracted-$arch/snell-server" ]]
    cmp /bin/true "$tmp/extracted-$arch/snell-server"
    "$READELF_BIN" -h "$tmp/extracted-$arch/snell-server" >/dev/null
done

run_sync() {
    local source=$1 repository=$2 expected=$3
    local output="$tmp/sync.log" github_output="$tmp/github-output"
    : > "$github_output"
    SNELL_SYNC_ROOT="$repository" \
    SNELL_RELEASE_NOTES_URL="file://$tmp/releases.md" \
    SNELL_DOWNLOAD_BASE_URL="file://$tmp/$source" \
    GITHUB_OUTPUT="$github_output" \
        bash "$root/scripts/sync-official-archives.sh" >"$output" 2>&1
    grep -Fxq "changed=$expected" "$output"
    [[ "$(< "$github_output")" == "changed=$expected" ]]
}

# A failure at any architecture must discard the entire staged release.
for scenario in bad-amd64 bad-i386 bad-aarch64 bad-armv7l bad-all missing; do
    repository="$tmp/repo-$scenario-new"
    mkdir -p "$repository"
    run_sync "$scenario" "$repository" 0
    [[ ! -e "$repository/Version/$version" ]]
    [[ -z "$(find "$repository/Version" -type f -print -quit)" ]]

    repository="$tmp/repo-$scenario-existing"
    mkdir -p "$repository/Version/$version"
    cp "$tmp/existing/"*.zip "$repository/Version/$version/"
    run_sync "$scenario" "$repository" 0
    for arch in "${arches[@]}"; do
        file="snell-server-${version}-linux-${arch}.zip"
        cmp "$tmp/existing/$file" "$repository/Version/$version/$file"
    done
    [[ "$(find "$repository/Version" -type f | wc -l)" -eq 4 ]]
done

repository="$tmp/repo-valid"
mkdir -p "$repository/Version/$version"
cp "$tmp/existing/"*.zip "$repository/Version/$version/"
run_sync valid "$repository" 1
for arch in "${arches[@]}"; do
    file="snell-server-${version}-linux-${arch}.zip"
    cmp "$tmp/valid/$file" "$repository/Version/$version/$file"
done
run_sync valid "$repository" 0

printf 'Archive validation tests passed (CRC rejection, atomic skip, valid sync).\n'
