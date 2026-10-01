#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # SHA, DIGEST, GITHUB_REPOSITORY, GITHUB_REF, GITHUB_OUTPUT set by the runner/workflow

if [[ "$GITHUB_REF" != refs/heads/main ]] ||
   [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]] ||
   [[ ! "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
   ! git merge-base --is-ancestor "$SHA" origin/main; then
  echo 'Release must be a published commit on main' >&2
  exit 1
fi
echo "source=ghcr.io/${GITHUB_REPOSITORY,,}-web@${DIGEST}" >> "$GITHUB_OUTPUT"
