#!/usr/bin/env bash
set -euo pipefail
: "${PROJECT_ID:?}" "${REGION:?}" "${SERVICE:?}" "${SHA:?}" "${GITHUB_OUTPUT:?}"
gcloud_opts=(--project "$PROJECT_ID" --region "$REGION" --quiet)

case "${1:?usage: deploy-cloud-run.sh <deploy|promote>}" in
  deploy)
    : "${IMAGE:?}"
    gcloud run deploy "$SERVICE" --image "$IMAGE" "${gcloud_opts[@]}" \
      --no-traffic --tag candidate --update-env-vars "GIT_SHA=$SHA"
    gcloud run services describe "$SERVICE" "${gcloud_opts[@]}" --format=json |
      jq -er '.status.traffic[] | select(.tag == "candidate") |
        "url=\(.url)\nrevision=\(.revisionName)"' >> "$GITHUB_OUTPUT"
    ;;
  promote)
    : "${REVISION:?}" "${GITHUB_STEP_SUMMARY:?}"
    gcloud run services update-traffic "$SERVICE" "${gcloud_opts[@]}" \
      --to-revisions "$REVISION=100"
    url="$(gcloud run services describe "$SERVICE" "${gcloud_opts[@]}" --format='value(status.url)')"
    echo "url=$url" >> "$GITHUB_OUTPUT"
    echo "Promoted $REVISION ($SHA) to 100% traffic" >> "$GITHUB_STEP_SUMMARY"
    ;;
  *)
    echo 'usage: deploy-cloud-run.sh <deploy|promote>' >&2
    exit 1
    ;;
esac