#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # Variables are set by the runner/calling workflow.

if [[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]]; then
  if [[ ! "$SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo '::error::SHA must be 7-40 lowercase hex characters' >&2
    exit 1
  fi
  SHA="$(git rev-parse --verify --end-of-options "${SHA}^{commit}")"
  artifact="web-release-$SHA"

  release_run_id="$(gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$artifact" --jq '
    [.artifacts[] | select(.expired | not)] | max_by(.created_at) | .workflow_run.id // empty')"
  if [[ -z "$release_run_id" ]]; then
    echo "::error::No published release found for $SHA" >&2
    exit 1
  fi

  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$release_run_id" |
    jq -e --arg repo "$GITHUB_REPOSITORY" '
      select(.path == ".github/workflows/cd.yml" and .event == "workflow_run" and
             .head_branch == "main" and .head_repository.full_name == $repo)' > /dev/null
  # The CD run may still be awaiting approval later on, so only its publish job must have succeeded.
  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$release_run_id/jobs" |
    jq -e '.jobs[] | select(.name == "publish" and .conclusion == "success")' > /dev/null

  release_file="$RUNNER_TEMP/release/web-release.json"
  gh run download "$release_run_id" --repo "$GITHUB_REPOSITORY" \
    --name "$artifact" --dir "$RUNNER_TEMP/release"
  [[ "$(jq -er '.sha' "$release_file")" == "$SHA" ]]
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