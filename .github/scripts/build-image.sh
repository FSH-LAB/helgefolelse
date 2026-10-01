#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # SHA, GITHUB_REPOSITORY, GITHUB_OUTPUT set by the calling workflow step

image="ghcr.io/${GITHUB_REPOSITORY,,}-web"
docker build --pull -f apps/web/Dockerfile \
  --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY}" \
  --label "org.opencontainers.image.revision=${SHA}" \
  -t "${image}:${SHA}" .
echo "name=${image}" >> "$GITHUB_OUTPUT"
