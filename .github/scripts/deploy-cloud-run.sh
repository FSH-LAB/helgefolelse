#!/usr/bin/env bash
set -euo pipefail
: "${IMAGE:?}" "${PROJECT_ID:?}" "${REGION:?}" "${SERVICE:?}" "${SHA:?}"
: "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"
PREVIEW_TAG="${PREVIEW_TAG:-}"
CANARY_PERCENT="${CANARY_PERCENT:-}"
CANARY_SECONDS="${CANARY_SECONDS:-300}"
tag="${PREVIEW_TAG:-candidate}"
gcloud_opts=(--project "$PROJECT_ID" --region "$REGION" --quiet)

gcloud run deploy "$SERVICE" --image "$IMAGE" "${gcloud_opts[@]}" \
  --no-traffic --tag "$tag" --update-env-vars "GIT_SHA=$SHA"
service="$(gcloud run services describe "$SERVICE" "${gcloud_opts[@]}" --format=json)"
candidate="$(jq -c --arg tag "$tag" '.status.traffic[] | select(.tag == $tag)' <<< "$service")"
candidate_url="$(jq -er .url <<< "$candidate")"
candidate_revision="$(jq -er .revisionName <<< "$candidate")"
"$(dirname "$0")/smoke-test.sh" "$candidate_url"

if [[ -n "$PREVIEW_TAG" ]]; then
  echo "url=$candidate_url" >> "$GITHUB_OUTPUT"
  echo "Preview $PREVIEW_TAG for $SHA: $candidate_url" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

if [[ -n "$CANARY_PERCENT" ]]; then
  if [[ ! "$CANARY_PERCENT" =~ ^[1-9][0-9]?$ || ! "$CANARY_SECONDS" =~ ^[0-9]+$ ]]; then
    echo '::error::CANARY_PERCENT must be 1-99 and CANARY_SECONDS a number' >&2
    exit 1
  fi
  stable_revision="$(jq -er '[.status.traffic[] | select(.percent > 0)] | max_by(.percent)
    | .revisionName' <<< "$service")"
  gcloud run services update-traffic "$SERVICE" "${gcloud_opts[@]}" --to-revisions \
    "$candidate_revision=$CANARY_PERCENT,$stable_revision=$((100 - CANARY_PERCENT))"
  echo "Canary: $CANARY_PERCENT% to $candidate_revision for ${CANARY_SECONDS}s" >> "$GITHUB_STEP_SUMMARY"
  start="$(date -u +%FT%TZ)"
  sleep "$CANARY_SECONDS"

  filter="metric.type=\"run.googleapis.com/request_count\""
  filter+=" AND resource.labels.service_name=\"$SERVICE\""
  filter+=" AND resource.labels.revision_name=\"$candidate_revision\""
  filter+=" AND metric.labels.response_code_class=\"5xx\""
  errors="$(curl --fail --show-error --silent --get \
    --header @<(printf 'Authorization: Bearer %s' "$(gcloud auth print-access-token)") \
    --data-urlencode "filter=$filter" \
    --data-urlencode "interval.startTime=$start" \
    --data-urlencode "interval.endTime=$(date -u +%FT%TZ)" \
    "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/timeSeries" |
    jq '[.timeSeries[]?.points[]?.value.int64Value | tonumber] | add // 0')"
  if (( errors > 0 )); then
    gcloud run services update-traffic "$SERVICE" "${gcloud_opts[@]}" \
      --to-revisions "$stable_revision=100"
    echo "::error::Canary served $errors 5xx responses; rolled back to $stable_revision" >&2
    exit 1
  fi
fi

gcloud run services update-traffic "$SERVICE" "${gcloud_opts[@]}" \
  --to-revisions "$candidate_revision=100"
echo "url=$(jq -r .status.url <<< "$service")" >> "$GITHUB_OUTPUT"
echo "Promoted $candidate_revision ($SHA) to 100% traffic" >> "$GITHUB_STEP_SUMMARY"
