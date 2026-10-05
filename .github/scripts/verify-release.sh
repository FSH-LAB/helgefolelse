#!/usr/bin/env bash
set -euo pipefail
: "${GITHUB_REF:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_OUTPUT:?}" "${GH_TOKEN:?}"
SHA="${SHA:-}"
RELEASE="${RELEASE:-}"
DIGEST="${DIGEST:-}"

if [[ "$GITHUB_REF" != refs/heads/main ]]; then
  echo '::error::Deployments must run from main' >&2
  exit 1
fi

image="ghcr.io/${GITHUB_REPOSITORY,,}-web"
if [[ -z "${DIGEST:-}" ]]; then
  release="${RELEASE:-$SHA}"
  if [[ "$release" =~ ^[0-9a-f]{7,40}$ ]]; then
    SHA="$(gh api "repos/$GITHUB_REPOSITORY/commits/$release" --jq .sha)"
  else
    if [[ ! "$release" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
      echo '::error::Release must be a commit SHA or version tag such as v1.2.3' >&2
      exit 1
    fi
    tag="$release"
    if ! gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag" >/dev/null 2>&1; then
      if [[ "$tag" == v* ]]; then
        echo "::error::Git tag $tag was not found" >&2
        exit 1
      fi
      tag="v$tag"
      gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag" >/dev/null 2>&1
    fi
    SHA="$(gh api "repos/$GITHUB_REPOSITORY/commits/$tag" --jq .sha)"
  fi
fi
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ || ! "$DIGEST" =~ ^(sha256:[0-9a-f]{64})?$ ]]; then
  echo '::error::Could not resolve release to a valid commit and image digest' >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$SHA" origin/main; then
  echo '::error::Release commit is not on main' >&2
  exit 1
fi

if [[ -z "${DIGEST:-}" ]]; then
  DIGEST="$(docker buildx imagetools inspect "$image:$SHA" --format '{{ .Manifest.Digest }}')"
fi
[[ "$SHA" =~ ^[0-9a-f]{40}$ && "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]

# Only CI on main signs images, and publish only runs after the verify job succeeds.
gh attestation verify "oci://$image@$DIGEST" --repo "$GITHUB_REPOSITORY" \
  --signer-workflow "$GITHUB_REPOSITORY/.github/workflows/ci.yml" \
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
