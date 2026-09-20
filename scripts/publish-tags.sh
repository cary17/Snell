#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../Snell.sh
SNELL_SOURCE_ONLY=1 source "$root/Snell.sh"

: "${VERSION:?}" "${IMAGE_DIGEST:?}" "${GHCR_OWNER:?}"
is_exact_version "$VERSION" || exit 1
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
version=${VERSION#v}
major=${version%%.*}
# Query again after the image has been built and verified, while the writer lock is held.
versions=$(get_official_versions) || { error "Official versions unavailable; rolling tags left unchanged."; exit 1; }
latest=$(tail -n 1 <<< "$versions")
major_latest=$(awk -F. -v major="$major" '$1 == major' <<< "$versions" | tail -n 1)
tags=()
[[ "$version" != "$latest" ]] || tags+=(latest)
[[ "$version" != "$major_latest" ]] || tags+=("v$major")
for tag in "${tags[@]}"; do
    docker buildx imagetools create --tag "ghcr.io/$GHCR_OWNER/snell:$tag" \
        "ghcr.io/$GHCR_OWNER/snell@$IMAGE_DIGEST"
    if [[ -n "${DOCKER_HUB_USERNAME:-}" ]]; then
        docker buildx imagetools create --tag "$DOCKER_HUB_USERNAME/snell:$tag" \
            "$DOCKER_HUB_USERNAME/snell@$IMAGE_DIGEST"
    fi
done
printf 'Official latest: v%s; published rolling tags: %s\n' "$latest" "${tags[*]:-none}"
