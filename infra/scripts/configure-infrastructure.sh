#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${ENVIRONMENT:?Select the already initialized environment backend first.}"
[[ "$ENVIRONMENT" =~ ^(dev|staging|production)$ ]] || exit 1
settings="$(terraform -chdir=infra output -json infrastructure_ci)"
printf '%s' "$settings" | jq -e --arg environment "$ENVIRONMENT" \
  'select(.inputs.environment == $environment and .inputs.enable_infrastructure_ci == true)' > /dev/null
repository="$(printf '%s' "$settings" | jq -er '.inputs.github_owner + "/" + .inputs.github_repository')"
reviewers="${REVIEWER_IDS:-$(printf '%s' "$settings" | jq -c '.inputs.reviewer_user_ids')}"
if [[ "${DEV_AUTO_APPLY_READY:-false}" == true ]]; then
  [[ "$ENVIRONMENT" == dev ]] || { echo 'Automatic approval is only allowed for dev.' >&2; exit 1; }
  reviewers='[]'
elif [[ "$ENVIRONMENT" == dev && "$reviewers" == '[]' ]]; then
  reviewers="[$(gh api user --jq .id)]"
fi
printf '%s' "$reviewers" | jq -e --arg automatic "${DEV_AUTO_APPLY_READY:-false}" \
  'select(type == "array" and (length > 0 or $automatic == "true") and length <= 6 and all(.[]; type == "number" and . > 0 and floor == .))' > /dev/null
deployment="$(terraform -chdir=infra output -json github_environment_variables)"

for mode in plan apply; do
  environment="infra-$ENVIRONMENT"
  selected_reviewers="$reviewers"
  if [[ "$mode" == plan ]]; then
    environment="infra-plan-$ENVIRONMENT"
    selected_reviewers='[]'
  fi
  jq -cn --argjson reviewers "$selected_reviewers" --arg environment "$ENVIRONMENT" --arg mode "$mode" \
    '{reviewers: ($reviewers | map({type: "User", id: .})), prevent_self_review: ($mode == "apply" and $environment != "dev"), can_admins_bypass: false,
      deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}' |
    gh api --method PUT "repos/$repository/environments/$environment" --input - > /dev/null
  policies="$(gh api "repos/$repository/environments/$environment/deployment-branch-policies" --paginate --slurp)"
  if ! printf '%s' "$policies" | jq -e 'any(.[].branch_policies[]; .name == "main" and .type == "branch")' > /dev/null; then
    gh api --method POST "repos/$repository/environments/$environment/deployment-branch-policies" \
      -f name=main -f type=branch > /dev/null
  fi
  if printf '%s' "$policies" | jq -e 'any(.[].branch_policies[]; .name != "main" or .type != "branch")' > /dev/null; then
    echo "Remove unexpected branch/tag policies from $environment before activation." >&2
    exit 1
  fi
  variables="$(printf '%s' "$settings" | jq -c --argjson deployment "$deployment" --arg mode "$mode" '
    $deployment + {
      TF_STATE_BUCKET: .state_bucket, TF_STATE_PREFIX: .state_prefix,
      TF_WIF_PROVIDER: .provider, TF_VARS_JSON: (.inputs | tojson)
    } + (if $mode == "plan" then {TF_PLAN_SERVICE_ACCOUNT: .plan_account} else {TF_APPLY_SERVICE_ACCOUNT: .apply_account} end)')"
  while IFS= read -r entry; do
    name="$(printf '%s' "$entry" | jq -r .key)"
    value="$(printf '%s' "$entry" | jq -r .value)"
    gh variable set "$name" --repo "$repository" --env "$environment" --body "$value"
  done < <(printf '%s' "$variables" | jq -c 'to_entries[]')
done
printf 'Configured infrastructure environments for %s. Automation remains disabled until explicitly enabled.\n' "$ENVIRONMENT"