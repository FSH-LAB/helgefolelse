#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # SOURCE, SHA, PROJECT_ID, REGION, REPOSITORY, GITHUB_OUTPUT set by the calling workflow step

target="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/web"
docker tag "$SOURCE" "$target:$SHA"
docker push "$target:$SHA"
digest="$(docker buildx imagetools inspect "$target:$SHA" --format '{{ .Manifest.Digest }}')"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
echo "image=$target@$digest" >> "$GITHUB_OUTPUT"
