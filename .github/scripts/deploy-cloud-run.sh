#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # Workflow-provided inputs and GITHUB_STEP_SUMMARY are set by the runner.

gcloud run deploy "$SERVICE" --image "$IMAGE" \
  --project "$PROJECT_ID" --region "$REGION" \
  --no-traffic --tag candidate --update-env-vars "GIT_SHA=$SHA" --quiet
candidate_url="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" --format=json |
  jq -er '.status.traffic[] | select(.tag == "candidate") | .url')"
health_response="$(curl --fail --show-error --silent --retry 5 --retry-delay 2 \
  --retry-all-errors "$candidate_url/api/health")"
if ! jq -e --arg sha "$SHA" '.status == "ok" and .commit == $sha' \
  <<< "$health_response" > /dev/null; then
  echo "::error::Candidate revision did not report expected commit $SHA" >&2
  echo "$health_response" >&2
  exit 1
fi

gcloud run services update-traffic "$SERVICE" --to-latest \
  --project "$PROJECT_ID" --region "$REGION" --quiet
echo "Promoted revision for $SHA to 100% traffic" >> "$GITHUB_STEP_SUMMARY"
