#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154 # IMAGE, PROJECT_ID, REGION, SERVICE set by the calling workflow step

gcloud run deploy "$SERVICE" --image "$IMAGE" \
  --project "$PROJECT_ID" --region "$REGION" --quiet
url="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" \
  --format='value(status.url)')"
curl --fail --show-error --silent --retry 5 --retry-delay 2 \
  --retry-all-errors "$url/api/health"
