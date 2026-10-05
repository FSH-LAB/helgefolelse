#!/usr/bin/env bash
set -euo pipefail
: "${SOURCE:?}" "${SHA:?}" "${PROJECT_ID:?}" "${REGION:?}"
: "${REPOSITORY:?}" "${GITHUB_OUTPUT:?}"

target="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/web"
skopeo copy --all --preserve-digests --authfile "$HOME/.docker/config.json" \
	"docker://$SOURCE" "docker://$target:$SHA"
digest="$(docker buildx imagetools inspect "$target:$SHA" --format '{{ .Manifest.Digest }}')"
if [[ "$digest" != "${SOURCE#*@}" ]]; then
	echo "::error::Mirror digest mismatch: expected ${SOURCE#*@}, got $digest" >&2
	exit 1
fi
echo "image=$target@$digest" >> "$GITHUB_OUTPUT"
