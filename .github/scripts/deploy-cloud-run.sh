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
"$(dirname "$0")/smoke-test.sh" "$candidate_url"

gcloud run services update-traffic "$SERVICE" \
  --to-revisions "$candidate_revision=100" \
  --project "$PROJECT_ID" --region "$REGION" --quiet
service_url="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" \
  --format='value(status.url)')"
echo "url=$service_url" >> "$GITHUB_OUTPUT"
echo "Promoted revision for $SHA to 100% traffic" >> "$GITHUB_STEP_SUMMARY"
