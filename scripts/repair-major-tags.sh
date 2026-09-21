#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../Snell.sh
SNELL_SOURCE_ONLY=1 source "$root/Snell.sh"

: "${GHCR_OWNER:?}"
[[ "$GHCR_OWNER" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { error "Invalid GHCR owner."; exit 1; }
if [[ -n "${MAJOR:-}" ]] && ! [[ "$MAJOR" =~ ^[0-9]+$ ]]; then
    error "Invalid requested major."
    exit 1
fi
if [[ -n "${DOCKER_HUB_USERNAME:-}" ]] && ! [[ "$DOCKER_HUB_USERNAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    error "Invalid Docker Hub username."
    exit 1
fi

declare -A versions_by_major
for record in "$root"/.build-records/v*.txt; do
    [ -f "$record" ] || continue
    version=$(awk -F= '$1 == "version" {print $2}' "$record")
    record_digest=$(awk -F= '$1 == "image_digest" {print $2}' "$record")
    is_exact_version "$version" || { error "Invalid version in $record."; exit 1; }
    major=${version#v}; major=${major%%.*}
    [[ -z "${MAJOR:-}" || "$MAJOR" == "$major" ]] || continue
    versions_by_major["$major"]+="${version#v}"$'\n'
done

versions=$(mktemp)
records=$(mktemp)
trap 'rm -f "$versions" "$records"' EXIT
for major in "${!versions_by_major[@]}"; do
    version=$(printf '%s' "${versions_by_major[$major]}" | sed '/^$/d' | sort_snell_versions | tail -n 1)
    [ -n "$version" ] || continue
    printf '%s\tv%s\n' "$major" "$version" >> "$versions"
done
[ -s "$versions" ] || { error "No successful build record found."; exit 1; }

ghcr_repo="ghcr.io/$GHCR_OWNER/snell"
dockerhub_repo=""
[[ -z "${DOCKER_HUB_USERNAME:-}" ]] || dockerhub_repo="docker.io/$DOCKER_HUB_USERNAME/snell"
while IFS=$'\t' read -r major version; do
    record="$root/.build-records/$version.txt"
    record_digest=$(awk -F= '$1 == "image_digest" {print $2}' "$record")
    [[ "$record_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { error "Invalid recorded digest for $version."; exit 1; }
    resolve_digest() {
        local repository=$1 resolved=""
        resolved=$(docker buildx imagetools inspect "$repository@$record_digest" --format '{{.Manifest.Digest}}' 2>/dev/null || true)
        if [[ "$resolved" == "$record_digest" ]]; then
            printf '%s\n' "$resolved"; return 0
        fi
        resolved=$(docker buildx imagetools inspect "$repository:$version" --format '{{.Manifest.Digest}}' 2>/dev/null || true)
        [[ "$resolved" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
        printf '%s\n' "$resolved"
    }
    ghcr_digest=$(resolve_digest "$ghcr_repo") || { error "Published GHCR image is unavailable for $version."; exit 1; }
    if [[ -n "$dockerhub_repo" ]]; then
        dockerhub_digest=$(resolve_digest "$dockerhub_repo") || {
            error "Published Docker Hub image is unavailable for $version."; exit 1;
        }
        [[ "$dockerhub_digest" == "$ghcr_digest" ]] || { error "Registry digest mismatch for $version."; exit 1; }
    fi
    printf '%s\t%s\t%s\n' "$major" "$version" "$ghcr_digest" >> "$records"
done < "$versions"

sort -n "$records" | while IFS=$'\t' read -r major version digest; do
    docker buildx imagetools create --tag "$ghcr_repo:v$major" "$ghcr_repo@$digest"
    if [[ -n "$dockerhub_repo" ]]; then
        docker buildx imagetools create --tag "$dockerhub_repo:v$major" "$dockerhub_repo@$digest"
    fi
    printf 'Published v%s -> %s (%s)\n' "$major" "$version" "$digest"
done
