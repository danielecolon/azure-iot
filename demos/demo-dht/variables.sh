#!/usr/bin/env bash
# variables.sh - the single place to configure this POC.
# Sourced by deploy.sh and remove.sh; do not run it on its own.

# ----------------------------------------------------------------------
# Subscription and location
# ----------------------------------------------------------------------
SUBSCRIPTION_ID=""   # empty = use current `az account show`
LOCATION="southcentralus"

# ----------------------------------------------------------------------
# Naming convention
#   <type>-poc-<POC_NAME>-<SUFFIX>   e.g. adf-poc-dht-93826
#   <type>poc<POC_NAME><SUFFIX>      for resources that disallow hyphens
# SUFFIX is 5 random digits picked once when this POC was created. Every
# resource in this POC shares it, which is how remove.sh finds them.
# ----------------------------------------------------------------------
POC_NAME="dht"   # short, lowercase letters/digits only
SUFFIX="93826"
BASE="poc-${POC_NAME}-${SUFFIX}"
BASE_COMPACT="poc${POC_NAME}${SUFFIX}"

# Shared lab resource group (already exists, holds other things too).
# deploy.sh creates it only if missing; remove.sh never deletes it.
RESOURCE_GROUP="rg-poc-iot-southcentralus-001"

# Tags put on every resource (remove.sh also uses pocSuffix to sweep leftovers)
TAGS=("purpose=poc" "poc=${POC_NAME}" "pocSuffix=${SUFFIX}" "ENV=demo")

# ----------------------------------------------------------------------
# Resource names (one variable per resource the POC creates)
# ----------------------------------------------------------------------
# IoT Hub: the cloud gateway the Pi connects to. Must be globally unique.
IOT_HUB_NAME="iot-${BASE}"
IOT_HUB_HOST="${IOT_HUB_NAME}.azure-devices.net"
# F1 is free, but a subscription can only have one F1 hub. If you already have
# one, use S1 here (it bills monthly, see README).
IOT_HUB_SKU="F1"
# Version of the IoT Hub device-registry REST API used to create the device.
IOT_REST_API_VERSION="2021-04-12"
# Version of the Azure Resource Manager API used to update the hub's routing.
IOT_ARM_API_VERSION="2023-06-30"

# The Pi's identity inside the hub
DEVICE_ID="pi-${BASE}"

# Storage account and container that keep the readings as JSON blobs
STORAGE_ACCOUNT_NAME="st${BASE_COMPACT}"   # 3-24 chars, lowercase alphanumeric
STORAGE_CONTAINER_NAME="readings"

# Message routing: an endpoint is a destination, a route sends messages to it
ROUTE_ENDPOINT_NAME="storage-readings"
ROUTE_NAME="all-readings"

# Written by deploy.sh next to the scripts, then copied to the Pi. Holds a secret.
DEVICE_CONNECTION_FILE="device-connection-string.txt"
