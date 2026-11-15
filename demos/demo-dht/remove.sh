#!/usr/bin/env bash
# remove.sh - deletes everything the dht POC created, EXCEPT the
# resource group. Run ./remove.sh --help for options.
set -uo pipefail # no -e: keep going if one delete fails

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=variables.sh
source "${SCRIPT_DIR}/variables.sh"

# The Windows az CLI (e.g. when called from WSL) ends lines with CRLF. Strip
# the \r so captured values like $(az ... -o tsv) compare and work correctly.
az() {
  command az "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

YES=false
DRY_RUN=false

usage() {
  cat << EOF
Usage: ./remove.sh [options]

  -y, --yes          Don't ask for confirmation
  -n, --dry-run      Print the az commands without running them
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)     YES=true ;;
    -n|--dry-run) DRY_RUN=true ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

run() {
  printf '\n\033[36m$' >&2
  printf ' %q' "$@" >&2
  printf '\033[0m\n' >&2
  if ! $DRY_RUN; then "$@"; fi
}

# Preflight: make sure we're logged in and on the right subscription.
if ! az account show -o none 2>/dev/null; then
  echo "Not logged in. Run: az login" >&2
  exit 1
fi
if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi
if [[ "$(az group exists --name "$RESOURCE_GROUP" -o json)" != "true" ]]; then
  echo "Resource group $RESOURCE_GROUP does not exist - nothing to remove."
  exit 0
fi

# Only this POC's resources: tagged with its suffix, or named with its full
# base. The RG is shared, so never match on the bare 5 digits.
QUERY="[?tags.pocSuffix=='${SUFFIX}' || contains(name, '${BASE}') || contains(name, '${BASE_COMPACT}')]"

echo "Subscription : $(az account show --query '[name, id]' -o tsv | paste -sd' ')"
echo "Resource grp : $RESOURCE_GROUP (will be kept)"
echo "Resources with suffix $SUFFIX:"
az resource list -g "$RESOURCE_GROUP" --query "$QUERY.{name:name, type:type}" -o table

if ! $YES && ! $DRY_RUN; then
  read -rp "Delete these resources? Type 'yes' to continue: " answer </dev/tty
  [[ "$answer" == "yes" ]] || { echo "Cancelled."; exit 0; }
fi

# --------------------------------------------------------------------------
# 1) Explicit deletes, in reverse order of deploy.sh (dependents first)
#    Includes purges for soft-deleted resources (Key Vault, AI services...).
# --------------------------------------------------------------------------
# Deleting the hub also deletes its device identity, endpoint and route.
run az iot hub delete --name "$IOT_HUB_NAME" --resource-group "$RESOURCE_GROUP" -o none
# Deleting the storage account also deletes the container and every reading.
run az storage account delete --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" --yes -o none
# The local copy of the device key is useless now that the device is gone.
run rm -f "${SCRIPT_DIR}/${DEVICE_CONNECTION_FILE}"

# --------------------------------------------------------------------------
# 2) Safety net: delete anything still left with this suffix. A few passes,
#    because some resources can't go until the ones depending on them do.
# --------------------------------------------------------------------------
if ! $DRY_RUN; then
  for pass in 1 2 3; do
    mapfile -t ids < <(az resource list -g "$RESOURCE_GROUP" --query "$QUERY.id" -o tsv)
    (( ${#ids[@]} == 0 )) && break
    echo "Sweep pass $pass: ${#ids[@]} resource(s) left"
    for id in "${ids[@]}"; do run az resource delete --ids "$id" -o none; done
  done
fi

echo
echo "Left in $RESOURCE_GROUP with suffix $SUFFIX:"
az resource list -g "$RESOURCE_GROUP" --query "$QUERY.{name:name, type:type}" -o table
echo "(empty above = clean). Resource group $RESOURCE_GROUP was kept."
