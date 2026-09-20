#!/usr/bin/env bash
set -euo pipefail

: "${SNELL_TEST_IMAGE:?Set SNELL_TEST_IMAGE to a locally built image}"
container="snell-regression-$$"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$container" --network none \
    -e LISTEN=32000 -e PSK=RegressionOnlyPsk16 -e DNS=1.1.1.1 "$SNELL_TEST_IMAGE" >/dev/null
ready=0
for _ in {1..10}; do
    if docker exec "$container" nc -z -w 1 127.0.0.1 32000 2>/dev/null; then ready=1; break; fi
    sleep 1
done
[[ "$ready" == 1 ]] || { docker logs "$container"; exit 1; }
docker stop -t 5 "$container" >/dev/null
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
[[ "$exit_code" == 0 || "$exit_code" == 143 ]] || { echo "Unexpected stop exit code: $exit_code" >&2; exit 1; }
printf 'test_container.sh: listener and graceful stop passed (exit=%s)\n' "$exit_code"
