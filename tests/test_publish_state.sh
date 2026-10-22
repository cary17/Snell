#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fixture="$tmp/repo"
mkdir -p "$fixture/scripts" "$fixture/.build-records" "$fixture/Version/v3.0.1" "$fixture/Version/v5.0.1"
cp "$root/Snell.sh" "$fixture/Snell.sh"
cp "$root/scripts/publish-tags.sh" "$fixture/scripts/publish-tags.sh"

# The tested checkout stays at A while publication records advance to B.
git -C "$fixture" init -q
git -C "$fixture" config user.name 'Publication Fixture'
git -C "$fixture" config user.email 'fixture@example.invalid'
for version in v3.0.1 v5.0.1 v6.0.0rc2; do
    printf 'version=%s\n' "$version" > "$fixture/.build-records/$version.txt"
done
git -C "$fixture" add .
git -C "$fixture" commit -qm 'Old publication records'
old_ref=$(git -C "$fixture" rev-parse HEAD)
for version in v3.0.2 v5.0.2; do
    printf 'version=%s\n' "$version" > "$fixture/.build-records/$version.txt"
done
git -C "$fixture" add .build-records
git -C "$fixture" commit -qm 'New publication records'
new_ref=$(git -C "$fixture" rev-parse HEAD)
git -C "$fixture" checkout -q --detach "$old_ref"

registry_calls="$tmp/registry-calls"
export registry_calls
curl() {
    [[ "${FAIL_LOOKUP:-0}" != 1 ]] || return 22
    local version
    while IFS= read -r version; do
        printf 'snell-server-v%s-linux-amd64.zip\n' "$version"
    done <<< "$OFFICIAL_VERSIONS"
}
docker() {
    printf '%s\n' "$*" >> "$registry_calls"
    if [[ "$*" == *'imagetools inspect'* ]]; then
        printf '%s\n' "$IMAGE_DIGEST"
    fi
}
sleep() { :; }
export -f curl docker sleep
export GHCR_OWNER=fixture DOCKER_HUB_USERNAME=fixture
IMAGE_DIGEST="sha256:$(printf '%064d' 0)"
export IMAGE_DIGEST
unset SNELL_PUBLISHED_STATE_REF GIT_OBJECT_DIRECTORY FAIL_LOOKUP

assert_tag() {
    grep -Fq -- "--tag $1 " "$registry_calls"
}
assert_no_tag() {
    if grep -Fq -- "--tag $1 " "$registry_calls"; then
        printf 'Unexpected formal tag: %s\n' "$1" >&2
        exit 1
    fi
}
assert_no_writes() {
    if grep -Fq 'buildx imagetools create' "$registry_calls"; then
        printf 'Formal tags were written after a failed gate\n' >&2
        exit 1
    fi
}
run_publish() {
    : > "$registry_calls"
    VERSION=$1 bash "$fixture/scripts/publish-tags.sh" > "$tmp/output" 2>&1
    [[ "$(grep -Fc 'buildx imagetools create' "$registry_calls")" == 2 ]]
    for repository in ghcr.io/fixture/snell docker.io/fixture/snell; do
        assert_tag "$repository:$1"
    done
}
assert_only_full_tag() {
    local major=${1#v} repository
    major=${major%%.*}
    for repository in ghcr.io/fixture/snell docker.io/fixture/snell; do
        assert_no_tag "$repository:v$major"
        assert_no_tag "$repository:latest"
    done
}
expect_failure() {
    local status=0
    : > "$registry_calls"
    VERSION=v5.0.1 bash "$fixture/scripts/publish-tags.sh" > "$tmp/output" 2>&1 || status=$?
    [[ "$status" == 1 ]]
    assert_no_writes
}

# No ref preserves local invocation, but live official major versions protect v5.
OFFICIAL_VERSIONS=$'5.0.2\n6.0.0rc2'
export OFFICIAL_VERSIONS
run_publish v5.0.1
assert_only_full_tag v5.0.1

# Current official v5 is older than the record in B; the old A checkout must not win.
export SNELL_PUBLISHED_STATE_REF="$new_ref"
OFFICIAL_VERSIONS=$'5.0.1\n6.0.0rc2'
run_publish v5.0.1
assert_only_full_tag v5.0.1

# Retired majors are protected by B even when absent from the official page.
OFFICIAL_VERSIONS=6.0.0rc2
run_publish v3.0.1
assert_only_full_tag v3.0.1
run_publish v5.0.1
assert_only_full_tag v5.0.1
run_publish v3.0.2
for repository in ghcr.io/fixture/snell docker.io/fixture/snell; do
    assert_tag "$repository:v3"
    assert_no_tag "$repository:latest"
done

# The supplied state replaces, rather than merges with, event snapshot records.
printf 'version=v3.0.99\n' > "$fixture/.build-records/v3.0.99.txt"
run_publish v3.0.2
for repository in ghcr.io/fixture/snell docker.io/fixture/snell; do
    assert_tag "$repository:v3"
done

# Missing and malformed refs stop all publication instead of using local records.
for ref in refs/heads/missing 'bad^{commit}'; do
    SNELL_PUBLISHED_STATE_REF=$ref expect_failure
done

# Use real Git failures: keep the tree readable but remove a record's blob.
cp -a "$fixture/.git/objects" "$tmp/broken-objects"
blob=$(git -C "$fixture" rev-parse "$new_ref:.build-records/v5.0.2.txt")
rm "$tmp/broken-objects/${blob:0:2}/${blob:2}"
GIT_OBJECT_DIRECTORY="$tmp/broken-objects" expect_failure

# Tree traversal can fail too; any partial listing must be discarded.
cp -a "$fixture/.git/objects" "$tmp/broken-tree-objects"
tree=$(git -C "$fixture" rev-parse "$new_ref:.build-records")
rm "$tmp/broken-tree-objects/${tree:0:2}/${tree:2}"
GIT_OBJECT_DIRECTORY="$tmp/broken-tree-objects" expect_failure

# Official lookup remains an all-or-nothing gate before any tag write.
FAIL_LOOKUP=1 expect_failure

# A valid newest candidate still receives the full, major and latest tags.
run_publish v6.0.0rc2
for repository in ghcr.io/fixture/snell docker.io/fixture/snell; do
    assert_tag "$repository:v6"
    assert_tag "$repository:latest"
done
[[ "$(git -C "$fixture" rev-parse HEAD)" == "$old_ref" ]]
[[ ! -e "$fixture/.build-records/v5.0.2.txt" ]]

printf 'test_publish_state.sh: passed\n'
