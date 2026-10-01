#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # SOURCE, SHA, DIGEST, GITHUB_REPOSITORY set by the calling workflow step

image="ghcr.io/${GITHUB_REPOSITORY,,}-web"
published_digest="$(docker buildx imagetools inspect "$image:$SHA" --format '{{ .Manifest.Digest }}')"
test "$published_digest" = "$DIGEST"
docker pull "$SOURCE"
revision="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$SOURCE")"
test "$revision" = "$SHA"
