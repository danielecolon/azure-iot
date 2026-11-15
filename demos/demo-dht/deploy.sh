#!/usr/bin/env bash
# deploy.sh - deploys the dht POC with the az CLI.
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

step_providers() {
  # A subscription must opt in to each Azure service ("resource provider")
  # before it can create that service's resources. Registering is free.
  local ns
  for ns in Microsoft.Devices Microsoft.Storage; do
    if [[ "$(az provider show --namespace "$ns" --query registrationState -o tsv)" == "Registered" ]]; then
      echo "$ns is already registered."
    else
      run az provider register --namespace "$ns" --wait -o none
    fi
  done
}

step_storage_account() {
  # The storage account is where the readings end up for long-term keeping.
  run az storage account create \
    --name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --allow-blob-public-access false \
    --tags "${TAGS[@]}" \
    -o none
}

step_storage_container() {
  # A container is a folder-like group of blobs. IoT Hub writes into this one.
  local key="DRY-RUN-KEY"
  if ! $DRY_RUN; then
    key=$(az storage account keys list --account-name "$STORAGE_ACCOUNT_NAME" \
      --resource-group "$RESOURCE_GROUP" --query '[0].value' -o tsv)
    SECRETS+=("$key")
  fi
  run az storage container create \
    --name "$STORAGE_CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --account-key "$key" \
    -o none
}

step_iot_hub() {
  # The hub is the secure front door that devices send messages to. It takes a
  # few minutes to create. The free tier (F1) allows at most 2 partitions.
  if az iot hub show --name "$IOT_HUB_NAME" --resource-group "$RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "IoT Hub $IOT_HUB_NAME already exists - leaving it as is."
    return 0
  fi
  run az iot hub create \
    --name "$IOT_HUB_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku "$IOT_HUB_SKU" \
    --partition-count 2 \
    --tags "${TAGS[@]}" \
    -o table
}

# Prints the names of the hub's routing items at a JSON path, for example
# endpoints.storageContainers or routes. Used to skip items that already exist.
hub_routing_names() {
  az iot hub show --name "$IOT_HUB_NAME" --resource-group "$RESOURCE_GROUP" \
    --query "properties.routing.$1[].name" -o tsv
}

# Adds one item to the hub's routing settings: reads the hub from Azure
# Resource Manager (ARM), appends the item, and writes the hub back with a PUT.
# This is what the deprecated "az iot hub routing-endpoint/route create" did
# for you; their replacements need the azure-iot extension, which this POC
# avoids. $1 = endpoints.storageContainers or routes, $2 = the item as JSON.
hub_add_routing_item() {
  local list="$1" item="$2" subscription url current body state i
  subscription=$(az account show --query id -o tsv)
  url="https://management.azure.com/subscriptions/${subscription}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Devices/IotHubs/${IOT_HUB_NAME}?api-version=${IOT_ARM_API_VERSION}"
  if $DRY_RUN; then
    current='{"location":"'"$LOCATION"'","properties":{"routing":{"endpoints":{"storageContainers":[]},"routes":[]}}}'
  else
    current=$(az rest --method get --url "$url" -o json)
  fi
  # Keep only what can be written back: drop read-only fields like hostName.
  body=$(LIST="$list" ITEM="$item" python3 -c '
import json, os, sys
hub = json.load(sys.stdin)
body = {k: hub[k] for k in ("location", "sku", "tags", "identity") if hub.get(k) is not None}
props = {k: v for k, v in hub["properties"].items() if v is not None
         and k not in ("provisioningState", "state", "hostName", "locations")}
for ep in props.get("eventHubEndpoints", {}).values():
    for k in ("partitionIds", "path", "endpoint"):
        ep.pop(k, None)
target = props["routing"]
*parents, leaf = os.environ["LIST"].split(".")
for key in parents:
    target = target.setdefault(key, {})
target.setdefault(leaf, []).append(json.loads(os.environ["ITEM"]))
body["properties"] = props
print(json.dumps(body))' <<< "$current")
  run az rest --method put --url "$url" --body "$body" -o none
  $DRY_RUN && return 0
  # The PUT returns before the hub has finished updating. Wait for it, because
  # the next step changes the hub again.
  for i in $(seq 1 60); do
    state=$(az iot hub show --name "$IOT_HUB_NAME" --resource-group "$RESOURCE_GROUP" \
      --query properties.provisioningState -o tsv)
    [[ "$state" == "Succeeded" ]] && return 0
    [[ "$state" == "Failed" ]] && { echo "Hub update failed." >&2; exit 1; }
    echo "Hub is $state - waiting..."
    sleep 10
  done
  echo "Timed out waiting for the hub update." >&2
  exit 1
}

step_message_endpoint() {
  # Tells the hub about the storage container as a destination. JSON encoding
  # gives readable blobs (the default is Avro). The hub collects messages and
  # writes a blob at most every 60 seconds, the shortest interval allowed.
  if ! $DRY_RUN && hub_routing_names endpoints.storageContainers | grep -qx "$ROUTE_ENDPOINT_NAME"; then
    echo "Endpoint $ROUTE_ENDPOINT_NAME already exists - leaving it as is."
    return 0
  fi
  local conn="DRY-RUN-CONNECTION-STRING" endpoint
  if ! $DRY_RUN; then
    conn=$(az storage account show-connection-string --name "$STORAGE_ACCOUNT_NAME" \
      --resource-group "$RESOURCE_GROUP" --query connectionString -o tsv)
    SECRETS+=("$conn")
  fi
  endpoint=$(NAME="$ROUTE_ENDPOINT_NAME" CONN="$conn" CONTAINER="$STORAGE_CONTAINER_NAME" \
    RG="$RESOURCE_GROUP" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["NAME"],
    "authenticationType": "keyBased",
    "connectionString": os.environ["CONN"],
    "containerName": os.environ["CONTAINER"],
    "resourceGroup": os.environ["RG"],
    "encoding": "JSON",
    "batchFrequencyInSeconds": 60,
    "maxChunkSizeInBytes": 314572800,
    "fileNameFormat": "{iothub}/{partition}/{YYYY}/{MM}/{DD}/{HH}/{mm}.json",
}))')
  hub_add_routing_item endpoints.storageContainers "$endpoint"
}

step_message_route() {
  # The route is the rule: every message from a device goes to the endpoint.
  if ! $DRY_RUN && hub_routing_names routes | grep -qx "$ROUTE_NAME"; then
    echo "Route $ROUTE_NAME already exists - leaving it as is."
    return 0
  fi
  local route
  route=$(NAME="$ROUTE_NAME" ENDPOINT="$ROUTE_ENDPOINT_NAME" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["NAME"],
    "source": "DeviceMessages",
    "condition": "true",
    "endpointNames": [os.environ["ENDPOINT"]],
    "isEnabled": True,
}))')
  hub_add_routing_item routes "$route"
}

# Builds a one-hour SAS token, the signed credential the hub's REST API expects.
# It is an HMAC-SHA256 of "<hub host>\n<expiry>", made with the hub's
# registryReadWrite policy key. This avoids needing the azure-iot az extension.
hub_registry_token() {
  local key expiry hex_key sig
  key=$(az iot hub policy show --hub-name "$IOT_HUB_NAME" --resource-group "$RESOURCE_GROUP" \
    --name registryReadWrite --query primaryKey -o tsv)
  expiry=$(( $(date +%s) + 3600 ))
  hex_key=$(printf '%s' "$key" | base64 -d | od -An -v -tx1 | tr -d ' \n')
  sig=$(printf '%s\n%s' "$IOT_HUB_HOST" "$expiry" \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${hex_key}" -binary \
    | base64 -w0 | sed 's/+/%2B/g; s#/#%2F#g; s/=/%3D/g')
  printf 'SharedAccessSignature sr=%s&sig=%s&se=%s&skn=registryReadWrite' \
    "$IOT_HUB_HOST" "$sig" "$expiry"
}

step_device() {
  # Registers the Pi in the hub. A device can't connect without an identity.
  # The hub generates the device's keys because the request doesn't supply any.
  local url="https://${IOT_HUB_HOST}/devices/${DEVICE_ID}?api-version=${IOT_REST_API_VERSION}"
  local token="DRY-RUN-TOKEN"
  if ! $DRY_RUN; then
    token=$(hub_registry_token)
    SECRETS+=("$token")
    if [[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: $token" "$url")" == "200" ]]; then
      echo "Device $DEVICE_ID already exists - leaving it as is."
      return 0
    fi
  fi
  run curl -sS --fail -X PUT "$url" \
    -H "Authorization: $token" \
    -H "Content-Type: application/json" \
    -d "{\"deviceId\":\"${DEVICE_ID}\"}" \
    -o /dev/null
}

step_device_connection_string() {
  # Saves the Pi's connection string to a file only you can read, so the key
  # never appears on screen. send_readings.py reads this file on the Pi.
  local path="${SCRIPT_DIR}/${DEVICE_CONNECTION_FILE}"
  if $DRY_RUN; then
    echo "Dry run: would look up the device key and write $path"
    return 0
  fi
  local url="https://${IOT_HUB_HOST}/devices/${DEVICE_ID}?api-version=${IOT_REST_API_VERSION}"
  local token key
  token=$(hub_registry_token)
  SECRETS+=("$token")
  key=$(curl -sS --fail -H "Authorization: $token" "$url" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["authentication"]["symmetricKey"]["primaryKey"])')
  SECRETS+=("$key")
  ( umask 077; printf 'HostName=%s;DeviceId=%s;SharedAccessKey=%s\n' \
      "$IOT_HUB_HOST" "$DEVICE_ID" "$key" > "$path" )
  echo "Saved the device connection string to $path"
}

# "function_name|Title shown to the user", in run order
STEPS=(
  "step_resource_group|Create resource group (if missing)"
  "step_providers|Register the IoT Hub and Storage resource providers (if needed)"
  "step_storage_account|Create the storage account"
  "step_storage_container|Create the blob container for the readings"
  "step_iot_hub|Create the IoT Hub (takes a few minutes)"
  "step_message_endpoint|Add the storage container as a hub endpoint"
  "step_message_route|Route all device messages to storage"
  "step_device|Register the Pi as a device identity"
  "step_device_connection_string|Save the device connection string to a file"
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
echo "IoT Hub      : $IOT_HUB_HOST"
echo "Device       : $DEVICE_ID"
echo "Blobs        : $STORAGE_ACCOUNT_NAME / container $STORAGE_CONTAINER_NAME"
echo "Next         : copy send_readings.py and $DEVICE_CONNECTION_FILE to the Pi (see README.md)"
