#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${ENVIRONMENT:?}" "${STATE_BUCKET:?}" "${STATE_PREFIX:?}" "${TFVARS_JSON:?}"
: "${GITHUB_SHA:?}" "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}"
: "${PROJECT_ID:?}"
[[ "$ENVIRONMENT" =~ ^(dev|staging|production)$ ]] || exit 1
if [[ "$STATE_PREFIX" != "helgefolelse/$ENVIRONMENT" ]]; then
  echo 'State prefix does not match the selected environment.' >&2
  exit 1
fi
[[ "$STATE_BUCKET" =~ ^[a-z0-9][a-z0-9._-]+[a-z0-9]$ ]] || exit 1
[[ "$GITHUB_SHA" =~ ^[a-f0-9]{40}$ ]] || exit 1
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]] || exit 1
plan_path="gs://$STATE_BUCKET/ci-plans/$ENVIRONMENT/$GITHUB_RUN_ID/$GITHUB_RUN_ATTEMPT/$GITHUB_SHA"

init() {
  printf '%s' "$TFVARS_JSON" | jq -e --arg environment "$ENVIRONMENT" --arg project "$PROJECT_ID" \
    'select(.environment == $environment and .project_id == $project and .enable_infrastructure_ci == true)' \
    > infra/ci.tfvars.json
  printf 'terraform { backend "gcs" {} }\n' > infra/backend_override.tf
  terraform -chdir=infra init -input=false -lockfile=readonly \
    -backend-config="bucket=$STATE_BUCKET" -backend-config="prefix=$STATE_PREFIX" \
    > infra/init.log 2>&1 || { echo 'Backend initialization failed; verify onboarding and permissions.' >&2; exit 1; }
  terraform -chdir=infra state list > infra/state-addresses.txt
  for address in google_project.environment google_storage_bucket.state google_cloud_run_v2_service.web; do
    grep -Fxq "$address" infra/state-addresses.txt || { echo 'Backend is not adopted; refusing an empty or incorrect state.' >&2; exit 1; }
  done
}

plan() {
  local exit_code=0
  terraform -chdir=infra plan -input=false -lock-timeout=5m -detailed-exitcode \
    -var-file=ci.tfvars.json -out=approved.tfplan > infra/plan.log 2>&1 || exit_code=$?
  [[ "$exit_code" == 0 || "$exit_code" == 2 ]] || { echo 'Terraform plan failed; reproduce with operator credentials for details.' >&2; exit 1; }
}

check_plan() {
  terraform -chdir=infra show -json approved.tfplan > infra/plan.json
  jq -e '.resource_changes | type == "array"' infra/plan.json > /dev/null
  jq '[.resource_changes[] | select(.mode == "managed" and .change.actions != ["no-op"])]' \
    infra/plan.json > infra/changes.json
  blocked="$(jq '[.[] | select(
    (.change.actions | index("delete")) or
    (.type | test("^github_|_iam_(member|binding|policy)$")) or
    (.type | IN("google_project", "google_storage_bucket", "google_iam_workload_identity_pool", "google_iam_workload_identity_pool_provider")) or
    (.address | startswith("google_service_account.infrastructure")) or
    (.type == "google_cloud_run_v2_service" and
      (.change.after.deletion_protection != true or
       .change.after.template[0].service_account != .change.before.template[0].service_account))
  )] | length' infra/changes.json)"
  changed="$(jq 'any(.resource_changes[]; .mode == "managed" and .change.actions != ["no-op"]) or
    any((.output_changes // {})[]; .actions != ["no-op"])' infra/plan.json)"
}

case "${1:?usage: infrastructure.sh <plan|drift|apply>}" in
  plan|drift)
    init
    plan
    check_plan
    {
      printf '## Infrastructure: %s\nCommit: %s\nPolicy violations: %s\n' "$ENVIRONMENT" "$GITHUB_SHA" "$blocked"
      jq -r '.[] | "- \(.address): \(.change.actions | join(", "))"' infra/changes.json
    } > infra/summary.md
    cat infra/summary.md >> "$GITHUB_STEP_SUMMARY"
    printf 'changed=%s\n' "$changed" >> "$GITHUB_OUTPUT"
    if [[ "$1" == plan ]]; then
      [[ "$blocked" == 0 ]] || { echo 'Plan blocked by policy; operator review required.' >&2; exit 1; }
      gcloud storage cp infra/approved.tfplan "$plan_path/" --quiet > /dev/null
    fi
    ;;
  apply)
    init
    latest_sha="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/main" --jq .object.sha)"
    [[ "$latest_sha" == "$GITHUB_SHA" ]] || { echo 'Commit superseded on main; generate a new plan.' >&2; exit 1; }
    gcloud storage cp "$plan_path/approved.tfplan" infra/ --quiet > /dev/null
    check_plan
    [[ "$blocked" == 0 ]] || { echo 'Saved plan violates policy.' >&2; exit 1; }
    jq -e --slurpfile inputs infra/ci.tfvars.json --argjson now "$(date +%s)" '
      .variables as $variables |
      ($now - (.timestamp | fromdateiso8601)) as $age |
      $age >= 0 and $age <= 14400 and
      all($inputs[0] | to_entries[]; . as $input | $input.value == $variables[$input.key].value)
    ' infra/plan.json > /dev/null || {
      echo 'Plan expired or inputs changed; generate a new plan and approve again.' >&2
      exit 1
    }
    terraform -chdir=infra apply -input=false -lock-timeout=5m approved.tfplan \
      > infra/apply.log 2>&1 || { echo 'Apply failed; preserve remote state and inspect with an operator before retrying.' >&2; exit 1; }
    terraform -chdir=infra plan -input=false -lock-timeout=5m -detailed-exitcode \
      -var-file=ci.tfvars.json > infra/post-apply.log 2>&1 || { echo 'Post-apply plan is not clean; operator investigation required.' >&2; exit 1; }
    echo "Applied infrastructure for $ENVIRONMENT at $GITHUB_SHA" >> "$GITHUB_STEP_SUMMARY"
    ;;
  *) exit 1 ;;
esac