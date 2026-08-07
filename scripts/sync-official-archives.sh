#!/usr/bin/env bash
set -euo pipefail

root=${SNELL_SYNC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
notes_url=${SNELL_RELEASE_NOTES_URL:-https://kb.nssurge.com/surge-knowledge-base/release-notes/snell.md}
base_url=${SNELL_DOWNLOAD_BASE_URL:-https://dl.nssurge.com/snell}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cd "$root"
mkdir -p Version

notes="$tmp/releases.md"
curl -fsSL --connect-timeout 15 --max-time 90 --retry 3 --retry-delay 5 "$notes_url" -o "$notes"

versions="$tmp/versions"
{
    grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+-linux-(amd64|i386|aarch64|armv7l)\.zip' "$notes" \
        | sed -E 's/^snell-server-(v[0-9]+\.[0-9]+\.[0-9]+)-linux-.*/\1/' || true
    find Version -type d -printf '%f\n' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true
} | sort -Vu > "$versions"

validate_archive() {
    local archive=$1 arch=$2 file=$3 extract_dir entries machine class
    entries=$(unzip -Z1 "$archive")
    [ "$entries" = snell-server ] || { echo "Unexpected ZIP contents: $file" >&2; return 1; }
    extract_dir="$tmp/extract-$arch"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    unzip -q "$archive" -d "$extract_dir"
    [ -x "$extract_dir/snell-server" ] || { echo "Non-executable binary: $file" >&2; return 1; }
    machine=$(LC_ALL=C readelf -h "$extract_dir/snell-server" | awk -F: '/Machine:/ {sub(/^[[:space:]]+/, "", $2); print $2}')
    class=$(LC_ALL=C readelf -h "$extract_dir/snell-server" | awk -F: '/Class:/ {sub(/^[[:space:]]+/, "", $2); print $2}')
    case "$arch:$class:$machine" in
        amd64:ELF64:*X86-64*|i386:ELF32:*Intel*80386*|aarch64:ELF64:*AArch64*|armv7l:ELF32:*ARM*) ;;
        *) echo "Architecture mismatch for $file: $class $machine" >&2; return 1 ;;
    esac
}

changed=0
while IFS= read -r version; do
    [ -n "$version" ] || continue
    version_tmp="$tmp/$version"
    mkdir -p "$version_tmp"
    complete=1

    for arch in amd64 i386 aarch64 armv7l; do
        file="snell-server-${version}-linux-${arch}.zip"
        archive="$version_tmp/$file"
        if ! curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 5 \
            "$base_url/$file" -o "$archive"; then
            echo "Incomplete official release $version: missing $file"
            complete=0
            break
        fi
        validate_archive "$archive" "$arch" "$file" || { complete=0; break; }
    done

    [ "$complete" = 1 ] || continue

    version_changed=0
    for arch in amd64 i386 aarch64 armv7l; do
        file="snell-server-${version}-linux-${arch}.zip"
        archive="$version_tmp/$file"
        destination="Version/${version}/${file}"
        official_sha=$(sha256sum "$archive" | cut -d' ' -f1)
        local_sha=""
        [ ! -f "$destination" ] || local_sha=$(sha256sum "$destination" | cut -d' ' -f1)
        [ "$official_sha" = "$local_sha" ] && continue
        version_changed=1
    done

    [ "$version_changed" = 1 ] || continue
    mkdir -p "Version/${version}"
    for arch in amd64 i386 aarch64 armv7l; do
        file="snell-server-${version}-linux-${arch}.zip"
        archive="$version_tmp/$file"
        destination="Version/${version}/${file}"
        official_sha=$(sha256sum "$archive" | cut -d' ' -f1)
        staging="$destination.tmp.$$"
        install -m 0644 "$archive" "$staging"
        mv -f "$staging" "$destination"
        echo "Updated: $destination ($official_sha)"
    done
    changed=1
done < "$versions"

printf 'changed=%s\n' "$changed"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'changed=%s\n' "$changed" >> "$GITHUB_OUTPUT"
fi
