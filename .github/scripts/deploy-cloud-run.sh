#!/usr/bin/env bash
set -euo pipefail
: "${IMAGE:?}" "${PROJECT_ID:?}" "${REGION:?}" "${SERVICE:?}" "${SHA:?}"
: "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"

gcloud run deploy "$SERVICE" --image "$IMAGE" \
  --project "$PROJECT_ID" --region "$REGION" \
  --no-traffic --tag candidate --update-env-vars "GIT_SHA=$SHA" --quiet
candidate="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" --format=json |
  jq -c '.status.traffic[] | select(.tag == "candidate")')"
candidate_url="$(jq -er .url <<< "$candidate")"
candidate_revision="$(jq -er .revisionName <<< "$candidate")"
health_response="$(curl --fail --show-error --silent --retry 5 --retry-delay 2 \
  --retry-all-errors "$candidate_url/api/health")"
if ! jq -e --arg sha "$SHA" '.status == "ok" and .commit == $sha' \
  <<< "$health_response" > /dev/null; then
  echo "::error::Candidate revision did not report expected commit $SHA" >&2
  echo "$health_response" >&2
  exit 1
fi

gcloud run services update-traffic "$SERVICE" \
  --to-revisions "$candidate_revision=100" \
  --project "$PROJECT_ID" --region "$REGION" --quiet
service_url="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" \
  --format='value(status.url)')"
echo "url=$service_url" >> "$GITHUB_OUTPUT"
echo "Promoted revision for $SHA to 100% traffic" >> "$GITHUB_STEP_SUMMARY"
