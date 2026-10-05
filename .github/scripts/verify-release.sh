#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # SHA, DIGEST, GITHUB_* set by the runner/workflow

if [[ "$GITHUB_REF" != refs/heads/main ]]; then
  echo '::error::Deployments must run from main' >&2
  exit 1
fi

image="ghcr.io/${GITHUB_REPOSITORY,,}-web"
if [[ -z "${DIGEST:-}" ]]; then
  if [[ ! "$SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo '::error::SHA must be 7-40 lowercase hex characters' >&2
    exit 1
  fi
  SHA="$(gh api "repos/$GITHUB_REPOSITORY/commits/$SHA" --jq .sha)"
  DIGEST="$(docker buildx imagetools inspect "$image:$SHA" --format '{{ .Manifest.Digest }}')"
fi
[[ "$SHA" =~ ^[0-9a-f]{40}$ && "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]

# Only CD on main signs images, and CD only runs after a green CI push on main.
gh attestation verify "oci://$image@$DIGEST" --repo "$GITHUB_REPOSITORY" \
  --signer-workflow "$GITHUB_REPOSITORY/.github/workflows/cd.yml" \
  --source-ref refs/heads/main --deny-self-hosted-runners

# Provenance records CD's trigger SHA, not the built commit, so check the signed image's label.
revision="$(docker buildx imagetools inspect "$image@$DIGEST" --format '{{ json .Image }}' |
  jq -r 'if has("config") then . else .["linux/amd64"] end
         | .config.Labels["org.opencontainers.image.revision"]')"
if [[ "$revision" != "$SHA" ]]; then
  echo "::error::Image $DIGEST was built from $revision, not $SHA" >&2
  exit 1
fi

printf 'sha=%s\nimage=%s\n' "$SHA" "$image@$DIGEST" >> "$GITHUB_OUTPUT"
