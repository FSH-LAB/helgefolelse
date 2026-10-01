#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # IMAGE, SHA, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY set by the calling workflow step

docker push "${IMAGE}:${SHA}"
digest="$(docker buildx imagetools inspect "${IMAGE}:${SHA}" --format '{{ .Manifest.Digest }}')"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
echo "digest=$digest" >> "$GITHUB_OUTPUT"
echo "Published ${IMAGE}@${digest} for ${SHA}" >> "$GITHUB_STEP_SUMMARY"
