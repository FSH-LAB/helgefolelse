#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # Variables are set by the runner/calling workflow.

if [[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]]; then
  if [[ ! "$RELEASE_RUN_ID" =~ ^[1-9][0-9]*$ ]]; then
    echo '::error::Release run ID must be numeric' >&2
    exit 1
  fi

  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$RELEASE_RUN_ID" |
    jq -e --arg repo "$GITHUB_REPOSITORY" '
      select(.path == ".github/workflows/cd.yml" and
             .event == "workflow_run" and .conclusion == "success" and
             .head_branch == "main" and .head_repository.full_name == $repo)' > /dev/null

  release_file="$RUNNER_TEMP/release/web-release.json"
  gh run download "$RELEASE_RUN_ID" --repo "$GITHUB_REPOSITORY" \
    --name web-release --dir "$RUNNER_TEMP/release"
  SHA="$(jq -er '.sha | strings | select(test("^[0-9a-f]{40}$"))' "$release_file")"
  DIGEST="$(jq -er '.digest | strings | select(test("^sha256:[0-9a-f]{64}$"))' "$release_file")"
  ci_run_id="$(jq -er '.ci_run_id | numbers | select(. > 0)' "$release_file")"
  [[ "$(jq -er '.ci_conclusion' "$release_file")" == success ]]

  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$ci_run_id" |
    jq -e --arg repo "$GITHUB_REPOSITORY" --arg sha "$SHA" '
      select(.path == ".github/workflows/ci.yml" and .event == "push" and
             .conclusion == "success" and .head_branch == "main" and .head_sha == $sha and
             .head_repository.full_name == $repo)' > /dev/null
fi

printf 'sha=%s\ndigest=%s\n' "$SHA" "$DIGEST" >> "$GITHUB_OUTPUT"