#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../Snell.sh
SNELL_SOURCE_ONLY=1 source "$root/Snell.sh"

: "${VERSION:?}" "${IMAGE_DIGEST:?}" "${GHCR_OWNER:?}"
is_exact_version "$VERSION" || { error "Invalid Snell version."; exit 1; }
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { error "Invalid image digest."; exit 1; }
[[ "$GHCR_OWNER" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { error "Invalid GHCR owner."; exit 1; }
if [[ -n "${DOCKER_HUB_USERNAME:-}" ]] && ! [[ "$DOCKER_HUB_USERNAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    error "Invalid Docker Hub username."
    exit 1
fi
version=${VERSION#v}
major=${version%%.*}
# Complete every read-only gate before writing any formal tag.
versions=$(get_official_versions) || { error "Official versions unavailable; formal tags left unchanged."; exit 1; }
latest=$(tail -n 1 <<< "$versions")
is_exact_version "$latest" || { error "Invalid official latest version."; exit 1; }
known_major_versions=$(for record in "$root"/.build-records/v*.txt; do
    [ -f "$record" ] || continue
    awk -F= -v major="$major" '$1 == "version" {value=$2; sub(/^v/, "", value); if (value ~ "^" major "\\.") print value}' "$record"
done
for directory in "$root"/Version/v*; do
    [ -d "$directory" ] || continue
    value=${directory##*/}; value=${value#v}
    if [[ "$value" == "$major".* ]]; then
        printf '%s\n' "$value"
    fi
done)
major_latest=$(printf '%s\n' "$known_major_versions" "$version" | sed '/^$/d' | sort_snell_versions | tail -n 1)
is_exact_version "$major_latest" || { error "No valid known version for major $major."; exit 1; }

ghcr_repo="ghcr.io/$GHCR_OWNER/snell"
dockerhub_repo=""
if [[ -n "${DOCKER_HUB_USERNAME:-}" ]]; then
    dockerhub_repo="docker.io/$DOCKER_HUB_USERNAME/snell"
fi

verify_candidate() {
    local repository=$1 actual_digest
    actual_digest=$(docker buildx imagetools inspect "$repository@$IMAGE_DIGEST" --format '{{.Manifest.Digest}}') || {
        error "Candidate digest is unavailable in $repository."
        return 1
    }
    [[ "$actual_digest" == "$IMAGE_DIGEST" ]] || {
        error "Candidate digest mismatch in $repository."
        return 1
    }
}

verify_candidate "$ghcr_repo"
[[ -z "$dockerhub_repo" ]] || verify_candidate "$dockerhub_repo"

tags=("v$version")
[[ "$version" != "$major_latest" ]] || tags+=("v$major")
[[ "$version" != "$latest" ]] || tags+=(latest)

publish_repository() {
    local repository=$1 tag
    local -a tag_args=()
    for tag in "${tags[@]}"; do
        tag_args+=(--tag "$repository:$tag")
    done
    docker buildx imagetools create "${tag_args[@]}" "$repository@$IMAGE_DIGEST"
}

publish_repository "$ghcr_repo"
[[ -z "$dockerhub_repo" ]] || publish_repository "$dockerhub_repo"

printf 'Official latest: v%s; published tags: %s\n' "$latest" "${tags[*]}"
printf 'docker pull %s:v%s\n' "$ghcr_repo" "$version"
if [[ -n "$dockerhub_repo" ]]; then
    printf 'docker pull %s:v%s\n' "$dockerhub_repo" "$version"
fi
