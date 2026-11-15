#!/usr/bin/env bash
# deploy.sh - deploys the livesensordata POC with the az CLI.
# Run ./deploy.sh --help for options.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=variables.sh
source "${SCRIPT_DIR}/variables.sh"

# The Windows az CLI (e.g. when called from WSL) ends lines with CRLF. Strip
# the \r so captured values like $(az ... -o tsv) compare and work correctly.
az() {
  command az "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

STEP_MODE=false
DRY_RUN=false
FROM=1
ONLY=""
LIST=false

usage() {
  cat << EOF
Usage: ./deploy.sh [options]

  -s, --steps        Pause before each step: [Enter] run, [s] skip, [q] quit
  -f, --from N       Start at step N (skip earlier steps)
  -o, --only N       Run only step N
  -n, --dry-run      Print the az commands without running them
  -l, --list         List the steps and exit
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--steps)   STEP_MODE=true ;;
    -f|--from)    FROM="${2:?--from needs a step number}"; shift ;;
    -o|--only)    ONLY="${2:?--only needs a step number}"; shift ;;
    -n|--dry-run) DRY_RUN=true ;;
    -l|--list)    LIST=true ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

# Values that run() replaces with REDACTED when it prints a command
# (passwords, keys). Steps can add more with: SECRETS+=("$key")
SECRETS=()

# Print a command (copy-pasteable, secrets hidden), then run it unless --dry-run.
run() {
  local arg secret shown=()
  for arg in "$@"; do
    for secret in ${SECRETS[@]+"${SECRETS[@]}"}; do
      [[ -n "$secret" ]] && arg="${arg//"$secret"/REDACTED}"
    done
    shown+=("$arg")
  done
  printf '\n\033[36m$' >&2
  printf ' %q' "${shown[@]}" >&2
  printf '\033[0m\n' >&2
  if ! $DRY_RUN; then "$@"; fi
}

# =========================================================================
# Steps - one function per step. A step is one command or a small group of
# commands that belong together. Add new steps to the STEPS list below.
# =========================================================================

step_resource_group() {
  # Creates the RG only if it doesn't already exist. remove.sh never deletes it.
  if [[ "$(az group exists --name "$RESOURCE_GROUP" -o json)" == "true" ]]; then
    echo "Resource group $RESOURCE_GROUP already exists - leaving it as is."
  else
    run az group create --name "$RESOURCE_GROUP" --location "$LOCATION" \
      --tags "${TAGS[@]}" -o table
  fi
}

step_check_readings() {
  # This POC only reads data. The storage account and container belong to the
  # demo-dht POC, so make sure that one is deployed first.
  if ! az storage account show --name "$DHT_STORAGE_ACCOUNT_NAME" \
      --resource-group "$RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "Storage account $DHT_STORAGE_ACCOUNT_NAME not found in $RESOURCE_GROUP." >&2
    echo "Deploy ../demo-dht first, or fix the DHT_* names in variables.sh." >&2
    $DRY_RUN || exit 1
    return 0
  fi
  echo "Found $DHT_STORAGE_ACCOUNT_NAME - the readings will come from container $DHT_STORAGE_CONTAINER_NAME."
}

step_static_web_app() {
  # A Static Web App serves the HTML/JS page from a global network and runs a
  # small Azure Functions API next to it, on the same URL (/api/...). The Free
  # tier is enough. No GitHub repo is linked: deploy.sh uploads the files.
  if az staticwebapp show --name "$STATIC_WEB_APP_NAME" --resource-group "$RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "Static Web App $STATIC_WEB_APP_NAME already exists - leaving it as is."
    return 0
  fi
  run az staticwebapp create \
    --name "$STATIC_WEB_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$SWA_LOCATION" \
    --sku Free \
    --tags "${TAGS[@]}" \
    -o table
}

step_app_settings() {
  # App settings are environment variables for the API. They tell it where the
  # readings are, and give it a SAS token: a signed URL suffix that allows
  # read + list on that one container only, until it expires.
  local key="DRY-RUN-KEY" sas="DRY-RUN-SAS" expiry
  expiry=$(date -u -d "+${SAS_DAYS} days" '+%Y-%m-%dT%H:%MZ')
  if ! $DRY_RUN; then
    key=$(az storage account keys list --account-name "$DHT_STORAGE_ACCOUNT_NAME" \
      --resource-group "$RESOURCE_GROUP" --query '[0].value' -o tsv)
    SECRETS+=("$key")
    sas=$(az storage container generate-sas \
      --account-name "$DHT_STORAGE_ACCOUNT_NAME" --account-key "$key" \
      --name "$DHT_STORAGE_CONTAINER_NAME" \
      --permissions rl --expiry "$expiry" --https-only -o tsv)
    SECRETS+=("$sas")
  fi
  run az staticwebapp appsettings set \
    --name "$STATIC_WEB_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --setting-names \
      "READINGS_CONTAINER_URL=https://${DHT_STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${DHT_STORAGE_CONTAINER_NAME}" \
      "READINGS_SAS=${sas}" \
      "READINGS_PREFIX=${DHT_IOT_HUB_NAME}" \
      "WINDOW_MINUTES=${WINDOW_MINUTES}" \
    -o none
  echo "SAS token expires $expiry. Re-run this step (./deploy.sh --only 4) to renew it."
}

step_api_packages() {
  # The API needs the Azure Functions library. The upload in the next step
  # sends the folder as-is, so the packages must be installed locally first.
  run npm install --prefix "${SCRIPT_DIR}/app/api" --omit=dev --no-audit --no-fund
}

step_upload_app() {
  # The deployment token is the Static Web App's upload password. The SWA CLI
  # (run with npx, nothing to install) uses it to publish app/src as the page
  # and app/api as the API, straight to the production environment.
  local token="DRY-RUN-TOKEN"
  if ! $DRY_RUN; then
    token=$(az staticwebapp secrets list --name "$STATIC_WEB_APP_NAME" \
      --resource-group "$RESOURCE_GROUP" --query properties.apiKey -o tsv)
    SECRETS+=("$token")
  fi
  (
    cd "${SCRIPT_DIR}/app"
    run env SWA_CLI_DEPLOYMENT_TOKEN="$token" \
      npx -y "@azure/static-web-apps-cli@${SWA_CLI_VERSION}" deploy ./src \
      --api-location ./api \
      --api-language node \
      --api-version 22 \
      --env production
  )
}

# "function_name|Title shown to the user", in run order
STEPS=(
  "step_resource_group|Create resource group (if missing)"
  "step_check_readings|Check that demo-dht's storage account exists"
  "step_static_web_app|Create the Static Web App (Free tier)"
  "step_app_settings|Give the API a read-only SAS token for the readings container"
  "step_api_packages|Install the API's npm packages locally"
  "step_upload_app|Upload the page and the API to the Static Web App"
)

# =========================================================================
# Runner
# =========================================================================

if $LIST; then
  for i in "${!STEPS[@]}"; do printf '%2d. %s\n' "$((i + 1))" "${STEPS[$i]#*|}"; done
  exit 0
fi

# Preflight: make sure we're logged in and on the right subscription.
if ! az account show -o none 2>/dev/null; then
  echo "Not logged in. Run: az login" >&2
  exit 1
fi
if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi
echo "Subscription : $(az account show --query '[name, id]' -o tsv | paste -sd' ')"
echo "Resource grp : $RESOURCE_GROUP ($LOCATION)"
echo "POC / suffix : $POC_NAME / $SUFFIX"
$DRY_RUN && echo "DRY RUN - commands are printed, not executed."

TOTAL=${#STEPS[@]}
for i in "${!STEPS[@]}"; do
  n=$((i + 1))
  fn="${STEPS[$i]%%|*}"
  title="${STEPS[$i]#*|}"
  if [[ -n "$ONLY" && "$n" -ne "$ONLY" ]]; then continue; fi
  if (( n < FROM )); then continue; fi

  printf '\n\033[1;33m=== Step %d/%d: %s ===\033[0m\n' "$n" "$TOTAL" "$title"
  if $STEP_MODE; then
    read -rp "[Enter] run, [s] skip, [q] quit: " answer </dev/tty
    case "$answer" in
      s|S) echo "Skipped."; continue ;;
      q|Q) echo "Stopped before step $n. Resume with: ./deploy.sh --steps --from $n"; exit 0 ;;
    esac
  fi
  "$fn"
done

printf '\n\033[1;32mDone.\033[0m\n'
if $DRY_RUN; then
  echo "Web app      : (created by step 3)"
else
  host=$(az staticwebapp show --name "$STATIC_WEB_APP_NAME" --resource-group "$RESOURCE_GROUP" \
    --query defaultHostname -o tsv 2>/dev/null || true)
  echo "Web app      : https://${host:-<not created yet>}"
  echo "API          : https://${host:-<not created yet>}/api/readings"
fi
echo "Readings     : $DHT_STORAGE_ACCOUNT_NAME / container $DHT_STORAGE_CONTAINER_NAME (from demo-dht)"
