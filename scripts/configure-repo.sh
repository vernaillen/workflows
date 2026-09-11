#!/usr/bin/env bash
#
# Set the GitHub Actions secrets and variables that coolify-deploy.yml needs on
# a repository that calls it.
#
# `vernaillen` is a personal account, not an organisation, so GitHub offers no
# org-level Actions secrets -- every repository carries its own copy. This
# script is what keeps those copies identical, and it is idempotent: re-run it
# whenever a credential rotates.
#
# Values are read at run time and piped into `gh` over stdin. Nothing is stored
# in this file, nothing reaches the process list, and no secret is ever printed
# -- which is also why no flag accepts a literal value.
#
# Usage:
#   scripts/configure-repo.sh --repo vernaillen/my-app [options]
#
# Options:
#   --repo OWNER/NAME      Target repository. Defaults to the `origin` remote of
#                          the current directory.
#   --match SUBSTRING      Matched against Coolify application names and FQDNs to
#                          find the application UUID. Defaults to the repository
#                          name with any dots removed.
#   --secret NAME[:KEY]    Also set secret NAME, read from KEY (default: NAME).
#   --var NAME[:KEY]       Also set variable NAME, read from KEY (default: NAME).
#   --build-secret ID:KEY  Add `ID=<value of KEY>` to the BUILD_SECRETS secret,
#                          which the pipeline mounts with --mount=type=secret.
#                          Repeatable; one line per id.
#   --smoke-env KEY        Add `KEY=<value>` to the SMOKE_ENV secret, which is
#                          handed to the smoke-test container as an env file.
#                          Repeatable. For variables the app needs merely to
#                          boot -- not for anything the build needs.
#   --dry-run              Resolve everything and print names and value lengths.
#                          Writes nothing.
#
# Per value, first hit wins:
#   1. the environment       e.g. COOLIFY_TOKEN=... scripts/configure-repo.sh ...
#   2. $COOLIFY_ENV          the shared registry + Coolify credentials
#   3. $PROJECT_ENV          ./.env of the app being configured
#   4. the Coolify API       (COOLIFY_APP_UUID only)
#   5. an interactive prompt

set -euo pipefail

COOLIFY_ENV=${COOLIFY_ENV:-$HOME/git/vernaillen/anneleenvernaillen.com/.env}
PROJECT_ENV=${PROJECT_ENV:-$PWD/.env}

REPO=${REPO:-}
MATCH=
DRY_RUN=false
EXTRA_SECRETS=
EXTRA_VARS=
BUILD_SECRET_SPECS=
SMOKE_ENV_KEYS=

usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

while [ $# -gt 0 ]; do
  case $1 in
    --repo)         REPO=${2:?--repo needs OWNER/NAME}; shift 2 ;;
    --match)        MATCH=${2:?--match needs a substring}; shift 2 ;;
    --secret)       EXTRA_SECRETS="${EXTRA_SECRETS}${2:?--secret needs NAME[:KEY]}"$'\n'; shift 2 ;;
    --var)          EXTRA_VARS="${EXTRA_VARS}${2:?--var needs NAME[:KEY]}"$'\n'; shift 2 ;;
    --build-secret) BUILD_SECRET_SPECS="${BUILD_SECRET_SPECS}${2:?--build-secret needs ID:KEY}"$'\n'; shift 2 ;;
    --smoke-env)    SMOKE_ENV_KEYS="${SMOKE_ENV_KEYS}${2:?--smoke-env needs KEY}"$'\n'; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  [ -n "$REPO" ] || { echo "no --repo given and no GitHub remote here" >&2; exit 2; }
fi
# Both sides of the comparison are lowercased and stripped of punctuation, so
# `harmonics.be` matches an application named `harmonics-be`.
normalise() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }
MATCH=$(normalise "${MATCH:-${REPO#*/}}")

# --- reading -----------------------------------------------------------------

# env_get <file> <key>  ->  value on stdout, non-zero when absent.
# Parses rather than sources the file: no code execution, no clobbering.
env_get() {
  local file=$1 key=$2 line
  [ -f "$file" ] || return 1
  line=$(grep -aE "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" | tail -n1) || return 1
  [ -n "$line" ] || return 1
  line=${line#*=}
  line=${line%$'\r'}
  case $line in
    \"*\") line=${line#\"}; line=${line%\"} ;;
    \'*\') line=${line#\'}; line=${line%\'} ;;
  esac
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

# resolve <key> [<prompt>] [<fallback-key>...]
resolve() {
  local key=$1 prompt=${2:-$1} v k f
  shift 2 2>/dev/null || shift $#
  eval "v=\${$key:-}"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  for k in "$key" "$@"; do
    for f in "$COOLIFY_ENV" "$PROJECT_ENV"; do
      if v=$(env_get "$f" "$k"); then printf '%s' "$v"; return 0; fi
    done
  done
  [ -t 0 ] || { echo "no value for $key and no terminal to ask on" >&2; return 1; }
  read -r -p "$prompt: " v
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# COOLIFY_URL is the instance root. Some projects store the whole webhook in
# COOLIFY_DEPLOY_URL (root + /api/v1/deploy?uuid=...), so fall back to its origin.
coolify_url() {
  local v
  if v=$(resolve COOLIFY_URL 2>/dev/null); then printf '%s' "${v%/}"; return 0; fi
  if v=$(env_get "$COOLIFY_ENV" COOLIFY_DEPLOY_URL || env_get "$PROJECT_ENV" COOLIFY_DEPLOY_URL); then
    v=$(printf '%s' "$v" | sed -E 's#^(https?://[^/]+).*#\1#')
    case $v in http*://?*) printf '%s' "$v"; return 0 ;; esac
  fi
  [ -t 0 ] || return 1
  read -r -p "Coolify instance URL (no trailing slash): " v
  [ -n "$v" ] || return 1
  printf '%s' "${v%/}"
}

# The UUID identifies one application, so it cannot be copied from another
# project. Ask Coolify which of its applications this repository is.
discover_app_uuid() {
  local token=$1 base=$2 json matches count
  command -v jq >/dev/null 2>&1 || { echo "  (jq not installed, skipping Coolify lookup)" >&2; return 1; }
  json=$(curl -fsS --max-time 15 "$base/api/v1/applications" \
    -H "Authorization: Bearer $token") || return 1
  matches=$(printf '%s' "$json" | jq -r --arg m "$MATCH" '
    (if type == "array" then . else (.data // []) end)
    | map(select((((.name // "") + " " + (.fqdn // "")) | ascii_downcase | gsub("[^a-z0-9]"; "")) | contains($m)))
    | .[] | "\(.uuid)\t\(.name // "?")\t\(.fqdn // "-")"') || return 1
  [ -n "$matches" ] || return 1
  count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
  if [ "$count" = 1 ]; then
    printf '%s' "$(printf '%s' "$matches" | cut -f1)"
    return 0
  fi
  echo "Several Coolify applications match '$MATCH':" >&2
  printf '%s\n' "$matches" | awk -F'\t' '{printf "  %s  %s  (%s)\n", $1, $2, $3}' >&2
  echo "Re-run with a narrower --match, or COOLIFY_APP_UUID=<uuid>." >&2
  return 1
}

# --- writing -----------------------------------------------------------------

failed=0

set_secret() {
  local name=$1 value=${2:-}
  if [ -z "$value" ]; then
    echo "  ! $name: no value found, skipped" >&2
    failed=$((failed + 1))
    return 0
  fi
  if $DRY_RUN; then
    echo "  - would set secret   $name (${#value} characters)"
    return 0
  fi
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO"
}

# Variables are not secret, so they are printed: seeing the wrong URL or UUID
# here is the point.
set_variable() {
  local name=$1 value=${2:-}
  if [ -z "$value" ]; then
    echo "  ! $name: no value found, skipped" >&2
    failed=$((failed + 1))
    return 0
  fi
  if $DRY_RUN; then
    echo "  - would set variable $name = $value"
    return 0
  fi
  printf '%s' "$value" | gh variable set "$name" --repo "$REPO"
}

# NAME:KEY -> resolve KEY, write as NAME. Bare NAME means KEY == NAME.
set_from_spec() {
  local kind=$1 spec=$2 name key value
  name=${spec%%:*}
  key=${spec#*:}
  [ "$key" != "$spec" ] || key=$name
  value=$(resolve "$key" "$name" || true)
  case $kind in
    secret) set_secret "$name" "$value" ;;
    var)    set_variable "$name" "$value" ;;
  esac
}

# --- run ---------------------------------------------------------------------

command -v gh >/dev/null 2>&1 || { echo "gh is not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "not logged in: run 'gh auth login'" >&2; exit 1; }

echo "repository:   $REPO"
echo "coolify match: $MATCH"
echo "shared .env:  $COOLIFY_ENV$([ -f "$COOLIFY_ENV" ] || echo '  (missing)')"
echo "project .env: $PROJECT_ENV$([ -f "$PROJECT_ENV" ] || echo '  (missing)')"
$DRY_RUN && echo "mode:         dry run, nothing is written"
echo

# REGISTRY_USERNAME is the name coolify-deploy.yml uses. REGISTRY_USER is what
# some .env files and two of the old workflows called it, so try both.
registry_username=$(resolve REGISTRY_USERNAME 'Registry username' REGISTRY_USER || true)
registry_password=$(resolve REGISTRY_PASSWORD 'Registry password' || true)
coolify_token=$(resolve COOLIFY_TOKEN 'Coolify API token' || true)
coolify_base=$(coolify_url || true)

app_uuid=${COOLIFY_APP_UUID:-}
if [ -z "$app_uuid" ] && [ -n "$coolify_token" ] && [ -n "$coolify_base" ]; then
  app_uuid=$(discover_app_uuid "$coolify_token" "$coolify_base" || true)
  [ -n "$app_uuid" ] && echo "found one Coolify application matching '$MATCH': $app_uuid" && echo
fi
if [ -z "$app_uuid" ] && [ -t 0 ]; then
  echo "The application UUID is per application: copy it from the URL of the"
  echo "Docker Image application in Coolify, or leave this empty to configure"
  echo "everything else and skip the deploy job for now."
  read -r -p "COOLIFY_APP_UUID (optional): " app_uuid
  echo
fi

set_secret   REGISTRY_USERNAME "$registry_username"
set_secret   REGISTRY_PASSWORD "$registry_password"
set_secret   COOLIFY_TOKEN     "$coolify_token"
set_variable COOLIFY_URL       "$coolify_base"
set_variable COOLIFY_APP_UUID  "$app_uuid"

# Both of these are multi-line secrets assembled from several sources, so they
# are built up here rather than resolved as one value.
build_secrets=
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  id=${spec%%:*}
  key=${spec#*:}
  [ "$key" != "$spec" ] || key=$id
  if value=$(resolve "$key" "build secret $id" ); then
    build_secrets="${build_secrets}${id}=${value}"$'\n'
  else
    echo "  ! BUILD_SECRETS/$id: no value found, skipped" >&2
    failed=$((failed + 1))
  fi
done <<< "$BUILD_SECRET_SPECS"
[ -n "$build_secrets" ] && set_secret BUILD_SECRETS "$build_secrets"

smoke_env=
while IFS= read -r key; do
  [ -n "$key" ] || continue
  if value=$(resolve "$key" "smoke-test env $key"); then
    smoke_env="${smoke_env}${key}=${value}"$'\n'
  else
    echo "  ! SMOKE_ENV/$key: no value found, skipped" >&2
    failed=$((failed + 1))
  fi
done <<< "$SMOKE_ENV_KEYS"
[ -n "$smoke_env" ] && set_secret SMOKE_ENV "$smoke_env"

while IFS= read -r spec; do
  [ -n "$spec" ] && set_from_spec secret "$spec"
done <<< "$EXTRA_SECRETS"

while IFS= read -r spec; do
  [ -n "$spec" ] && set_from_spec var "$spec"
done <<< "$EXTRA_VARS"

echo
if [ "$failed" -gt 0 ]; then
  echo "$failed value(s) could not be resolved; the pipeline will fail until they are set." >&2
  exit 1
fi
$DRY_RUN && exit 0

echo "Done."
echo "  gh secret list   --repo $REPO"
echo "  gh variable list --repo $REPO"

# Left over from the starter workflow this pipeline replaces. Harmless, but it
# is a credential for a product that no longer exists.
if gh secret list --repo "$REPO" 2>/dev/null | grep -q '^NUXT_UI_PRO_LICENSE'; then
  echo
  echo "Note: NUXT_UI_PRO_LICENSE is still set but nothing reads it any more."
  echo "  gh secret delete NUXT_UI_PRO_LICENSE --repo $REPO"
fi
# REGISTRY_USER is the old name; coolify-deploy.yml reads REGISTRY_USERNAME.
if gh secret list --repo "$REPO" 2>/dev/null | grep -q '^REGISTRY_USER[[:space:]]'; then
  echo
  echo "Note: REGISTRY_USER is the pre-shared-pipeline name and is now unused."
  echo "  gh secret delete REGISTRY_USER --repo $REPO"
fi
