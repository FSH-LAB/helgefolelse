#!/usr/bin/env bash
set -euo pipefail
: "${SOURCE:?}" "${SHA:?}" "${PROJECT_ID:?}" "${REGION:?}"
: "${REPOSITORY:?}" "${GITHUB_OUTPUT:?}"

target="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/web"
docker buildx imagetools create --tag "$target:$SHA" "$SOURCE"
digest="$(docker buildx imagetools inspect "$target:$SHA" --format '{{ .Manifest.Digest }}')"
[[ "$digest" == "${SOURCE#*@}" ]]
echo "image=$target@$digest" >> "$GITHUB_OUTPUT"
