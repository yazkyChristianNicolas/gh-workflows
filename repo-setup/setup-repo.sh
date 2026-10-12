#!/usr/bin/env bash
# Configures a repository for the build-once / promote deploy flow (see the README in this
# directory): branches, default branch, rulesets, Actions permissions, environments with
# their variables and branch policies, and secrets.
#
# Idempotent: it converges the repository to what the config says, so it can be re-run
# after editing the config. The config is the source of truth: values changed by hand in
# GitHub for keys present in the config are overwritten.
#
# Usage:
#   ./setup-repo.sh <config.json> [--dry-run]
#
# Secrets are never in the config, only their names. Values come from a local file outside
# git (default ~/.config/gh-workflows/secrets.env, override with GH_SETUP_SECRETS):
#   DEPLOY_HOST=203.0.113.10
#   DEPLOY_SSH_KEY=@~/.ssh/berlinesa_deploy      # @path = read the value from that file
#
# Requires: gh (logged in with admin access to the repository) and jq.

set -euo pipefail

CONFIG="${1:-}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true
SECRETS_FILE="${GH_SETUP_SECRETS:-$HOME/.config/gh-workflows/secrets.env}"

if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
  echo "Usage: $0 <config.json> [--dry-run]" >&2
  exit 1
fi
command -v gh > /dev/null || { echo "gh is required" >&2; exit 1; }
command -v jq > /dev/null || { echo "jq is required" >&2; exit 1; }

cfg() { jq -r "$1" "$CONFIG"; }

REPO="$(cfg '.repository')"
PROD_BRANCH="$(cfg '.branches.production // "main"')"
DEV_BRANCH="$(cfg '.branches.development // "development"')"

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }

# Runs a mutating command, or only prints it in dry-run mode.
apply() {
  if $DRY_RUN; then
    info "[dry-run] $*"
  else
    "$@" > /dev/null
  fi
}

# gh api with a JSON body read from stdin.
api_json() {
  local method="$1" path="$2" body
  body="$(cat)"
  if $DRY_RUN; then
    info "[dry-run] gh api -X $method $path $(jq -c . <<< "$body")"
  else
    gh api -X "$method" "$path" --input - <<< "$body" > /dev/null
  fi
}

# Value of a secret from the local secrets file (KEY=value or KEY=@path).
secret_value() {
  local name="$1" line value
  [ -f "$SECRETS_FILE" ] || { echo "Secrets file not found: $SECRETS_FILE" >&2; return 1; }
  line="$(grep -E "^${name}=" "$SECRETS_FILE" | tail -1 || true)"
  [ -n "$line" ] || { echo "Secret $name is not in $SECRETS_FILE" >&2; return 1; }
  value="${line#*=}"
  if [[ "$value" == @* ]]; then
    local path="${value#@}"
    path="${path/#\~/$HOME}"
    [ -f "$path" ] || { echo "File for secret $name not found: $path" >&2; return 1; }
    cat "$path"
  else
    printf '%s' "$value"
  fi
}

gh api "repos/$REPO" --jq .full_name > /dev/null \
  || { echo "Cannot read $REPO with the current gh login" >&2; exit 1; }
echo "Configuring $REPO$($DRY_RUN && echo ' (dry run)')"

# ---------------------------------------------------------------------------
step "Branches: $DEV_BRANCH (default) and $PROD_BRANCH"

if gh api "repos/$REPO/branches/$DEV_BRANCH" > /dev/null 2>&1; then
  info "$DEV_BRANCH exists"
else
  sha="$(gh api "repos/$REPO/git/ref/heads/$PROD_BRANCH" --jq .object.sha)"
  info "creating $DEV_BRANCH from $PROD_BRANCH ($sha)"
  api_json POST "repos/$REPO/git/refs" <<< "{\"ref\": \"refs/heads/$DEV_BRANCH\", \"sha\": \"$sha\"}"
fi

jq -n --arg branch "$DEV_BRANCH" '{ default_branch: $branch, delete_branch_on_merge: true }' \
  | api_json PATCH "repos/$REPO"
info "default branch $DEV_BRANCH, delete branches after merge"

# ---------------------------------------------------------------------------
step "Rulesets"

# One ruleset per branch: PR required, required status checks, no force push, no deletion.
upsert_ruleset() {
  local branch="$1" name="protect-$1" id body
  body="$(jq -n --arg name "$name" --arg ref "refs/heads/$branch" \
    --argjson checks "$(jq -c '.required_checks // []' "$CONFIG")" \
    --argjson approvals "$(jq '.required_approvals // 0' "$CONFIG")" '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: [$ref], exclude: [] } },
    rules: ([
      { type: "deletion" },
      { type: "non_fast_forward" },
      { type: "pull_request", parameters: {
          required_approving_review_count: $approvals,
          dismiss_stale_reviews_on_push: false,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: false } }
    ] + (if ($checks | length) > 0 then [
      { type: "required_status_checks", parameters: {
          strict_required_status_checks_policy: false,
          required_status_checks: ($checks | map({ context: . })) } }
    ] else [] end))
  }')"
  id="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null || true)"
  if [ -n "$id" ]; then
    info "updating $name"
    api_json PUT "repos/$REPO/rulesets/$id" <<< "$body"
  else
    info "creating $name"
    api_json POST "repos/$REPO/rulesets" <<< "$body"
  fi
}

if gh api "repos/$REPO/rulesets" > /dev/null 2>&1; then
  upsert_ruleset "$DEV_BRANCH"
  upsert_ruleset "$PROD_BRANCH"
else
  info "SKIPPED: rulesets are not available for this repository (private repos need GitHub Pro)"
fi

# ---------------------------------------------------------------------------
step "Actions permissions"

jq -n '{ default_workflow_permissions: "read", can_approve_pull_request_reviews: true }' \
  | api_json PUT "repos/$REPO/actions/permissions/workflow"
info "token read-only by default (workflows request what they need); Actions may open PRs"

# ---------------------------------------------------------------------------
step "Environments"

for env in $(cfg '.environments // {} | keys[]'); do
  info "$env"
  reviewers="$(jq -c --arg env "$env" '.environments[$env].reviewers // []' "$CONFIG")"
  branch="$(cfg ".environments[\"$env\"].branch // empty")"

  reviewer_objects="[]"
  for login in $(jq -r '.[]' <<< "$reviewers"); do
    uid="$(gh api "users/$login" --jq .id)"
    reviewer_objects="$(jq -c --argjson id "$uid" '. + [{ type: "User", id: $id }]' <<< "$reviewer_objects")"
  done

  jq -n --argjson reviewers "$reviewer_objects" --arg branch "$branch" '{
    reviewers: $reviewers,
    deployment_branch_policy: (if $branch == "" then null
      else { protected_branches: false, custom_branch_policies: true } end)
  }' | api_json PUT "repos/$REPO/environments/$env"

  if [ -n "$branch" ]; then
    existing="$(gh api "repos/$REPO/environments/$env/deployment-branch-policies" \
      --jq '.branch_policies[].name' 2>/dev/null || true)"
    if grep -qx "$branch" <<< "$existing"; then
      info "  only deploys from $branch (already set)"
    else
      info "  only deploys from $branch"
      api_json POST "repos/$REPO/environments/$env/deployment-branch-policies" \
        <<< "{\"name\": \"$branch\", \"type\": \"branch\"}"
    fi
  fi

  while IFS=$'\t' read -r name value; do
    [ -n "$name" ] || continue
    info "  variable $name=$value"
    apply gh variable set "$name" --env "$env" -R "$REPO" -b "$value"
  done < <(jq -r --arg env "$env" '.environments[$env].variables // {} | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG")

  for name in $(jq -r --arg env "$env" '.environments[$env].secrets // [] | .[]' "$CONFIG"); do
    info "  secret $name"
    if $DRY_RUN; then
      secret_value "$name" > /dev/null && info "  [dry-run] gh secret set $name --env $env"
    else
      secret_value "$name" | gh secret set "$name" --env "$env" -R "$REPO" > /dev/null
    fi
  done
done

# ---------------------------------------------------------------------------
step "Repository variables and secrets"

while IFS=$'\t' read -r name value; do
  [ -n "$name" ] || continue
  info "variable $name=$value"
  apply gh variable set "$name" -R "$REPO" -b "$value"
done < <(jq -r '.variables // {} | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG")

for name in $(cfg '.secrets // [] | .[]'); do
  info "secret $name"
  if $DRY_RUN; then
    secret_value "$name" > /dev/null && info "[dry-run] gh secret set $name"
  else
    secret_value "$name" | gh secret set "$name" -R "$REPO" > /dev/null
  fi
done

echo
echo "Done$($DRY_RUN && echo ' (dry run, nothing was changed)')."
