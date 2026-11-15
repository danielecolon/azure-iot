#!/usr/bin/env bash
# variables.sh - the single place to configure this POC.
# Sourced by deploy.sh and remove.sh; do not run it on its own.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

# ----------------------------------------------------------------------
# Subscription and location
# ----------------------------------------------------------------------
SUBSCRIPTION_ID=""   # empty = use current `az account show`
LOCATION="southcentralus"   # the resource group's region
# Static Web Apps isn't offered in southcentralus. This region only hosts the
# app's API (the page itself is served worldwide). Other options: eastus2,
# westus2, westeurope, eastasia.
SWA_LOCATION="centralus"

# ----------------------------------------------------------------------
# Naming convention
#   <type>-poc-<POC_NAME>-<SUFFIX>   e.g. stapp-poc-livesensordata-89592
#   <type>poc<POC_NAME><SUFFIX>      for resources that disallow hyphens
# SUFFIX is 5 random digits picked once when this POC was created. Every
# resource in this POC shares it, which is how remove.sh finds them.
# ----------------------------------------------------------------------
POC_NAME="livesensordata"   # short, lowercase letters/digits only
SUFFIX="89592"
BASE="poc-${POC_NAME}-${SUFFIX}"
BASE_COMPACT="poc${POC_NAME}${SUFFIX}"

# Shared lab resource group (already exists, holds other things too).
# deploy.sh creates it only if missing; remove.sh never deletes it.
RESOURCE_GROUP="rg-poc-iot-southcentralus-001"

# Tags put on every resource (remove.sh also uses pocSuffix to sweep leftovers)
TAGS=("purpose=poc" "poc=${POC_NAME}" "pocSuffix=${SUFFIX}")

# ----------------------------------------------------------------------
# Resource names (one variable per resource the POC creates)
# ----------------------------------------------------------------------
# Static Web App: hosts the page and its small API. Free tier.
STATIC_WEB_APP_NAME="stapp-${BASE}"

# ----------------------------------------------------------------------
# Where the readings come from: the demo-dht POC (NOT created or deleted here).
# These must match ../demo-dht/variables.sh.
# ----------------------------------------------------------------------
DHT_STORAGE_ACCOUNT_NAME="stpocdht93826"
DHT_STORAGE_CONTAINER_NAME="readings"
DHT_IOT_HUB_NAME="iot-poc-dht-93826"   # the hub names the top folder of every blob

# The API reads the container with a read+list SAS token that expires after
# this many days. Re-run the "app settings" step to get a fresh one.
SAS_DAYS=30

# The chart's starting range (minutes) when the page doesn't ask for one.
# The page's dropdown offers 1, 5, 15, 30, 60 and 1440.
WINDOW_MINUTES=5

# Version of the Static Web Apps CLI that uploads the app (run with npx)
SWA_CLI_VERSION="2.0.10"
