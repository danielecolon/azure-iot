# Raspberry Pi DHT11 to Azure IoT Hub POC

Proves that a Raspberry Pi 5 with a cheap DHT11 sensor can send temperature and
humidity readings to Azure. The scripts build an IoT Hub with one device identity
for the Pi, plus a storage account that keeps every reading in JSON blobs. A short
Python script on the Pi reads the sensor every 30 seconds and sends each reading
to the hub.

This is a proof of concept. It keeps the deployment simple and skips production
practices. Shortcuts taken: public endpoints, the Pi authenticates with a symmetric
key stored in a plain file, the hub reaches storage with a storage connection string,
and there is no monitoring or infrastructure as code.

## Files

| File | What it does |
|---|---|
| `variables.sh` | The only file to edit. Subscription, location, resource group, the POC name, the 5-digit suffix and every resource name. Sourced by the other scripts. |
| `deploy.sh` | Creates the resources with `az` commands, as numbered steps. Prints each command before running it. |
| `remove.sh` | Deletes every resource this POC created (matched by suffix `93826`), **but keeps the resource group**. |
| `send_readings.py` | Runs on the Pi. Reads the DHT11 every 30 seconds and sends each reading to the hub. |
| `README.md` | This file: how to run the scripts. |
| `dht.md` | Background: what this technology is, when it's used, and how it's normally used in real projects. |
| `device-connection-string.txt` | Created by `deploy.sh`. Holds the Pi's secret key, so don't commit or share it. `remove.sh` deletes it. |

## Naming

Every resource is named `<type>-poc-dht-93826` (or the same without hyphens
where hyphens aren't allowed, e.g. storage accounts) and tagged `pocSuffix=93826`.

| Resource | Name |
|---|---|
| IoT Hub | `iot-poc-dht-93826` |
| Device identity (inside the hub) | `pi-poc-dht-93826` |
| Storage account | `stpocdht93826` |
| Blob container | `readings` |
| Hub message endpoint | `storage-readings` |
| Hub message route | `all-readings` |

## Prerequisites

- `az login`, and the right subscription (set `SUBSCRIPTION_ID` in `variables.sh` or `az account set`)
- Permission to create resources in the resource group (and to create the RG if it doesn't exist)
- Permission to register resource providers on the subscription (step 2 needs this if `Microsoft.Devices` isn't registered yet)
- `curl`, `openssl` and `python3` on the machine that runs `deploy.sh`
- A Raspberry Pi 5 running Raspberry Pi OS, with internet access and outbound port 8883 (MQTT) open
- A DHT11 sensor and jumper wires

The scripts use only the core az CLI, with no extensions. `az iot hub routing-endpoint`
and `az iot hub route` are deprecated. Their replacements, `az iot hub message-endpoint`
and `az iot hub message-route`, need the `azure-iot` extension. So steps 6 and 7 read
the hub with `az rest`, add the endpoint or route to its routing settings, and write
the hub back with a PUT to Azure Resource Manager. Each takes a minute or two while
the hub updates. Step 8 creates the device identity through the IoT Hub REST API
with `curl`.

## Deploy

```bash
./deploy.sh --list           # show the steps
./deploy.sh --steps          # pause before each step ([Enter] run, [s] skip, [q] quit)
./deploy.sh                  # run everything
./deploy.sh --from 6         # resume at step 6
./deploy.sh --only 4         # run just step 4
./deploy.sh --dry-run        # print the commands only
```

Steps:

1. Create resource group (if missing)
2. Register the IoT Hub and Storage resource providers (if needed)
3. Create the storage account
4. Create the blob container for the readings
5. Create the IoT Hub (takes a few minutes)
6. Add the storage container as a hub endpoint
7. Route all device messages to storage
8. Register the Pi as a device identity
9. Save the device connection string to a file

## Try it

**1. Wire the sensor to the Pi.** Numbers are physical pin numbers on the header.

| DHT11 | Pi 5 pin |
|---|---|
| VCC (+) | Pin 1 (3.3V) |
| DATA (out) | Pin 7 (GPIO 4) |
| GND (-) | Pin 6 (Ground) |

A 3-pin DHT11 module already has the pull-up resistor it needs. A bare 4-pin
sensor needs a 10 kΩ resistor between VCC and DATA.

**2. Turn on the sensor driver on the Pi**, then reboot.

```bash
echo 'dtoverlay=dht11,gpiopin=4' | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

After the reboot, this should print a temperature in thousandths of a degree.
An occasional read error is normal, so try it again if you get one.

```bash
cat /sys/bus/iio/devices/iio:device*/in_temp_input
```

**3. Copy the two files from this folder to the Pi.** Replace the user and host with yours.

```bash
ssh pi@raspberrypi.local 'mkdir -p ~/dht'
scp send_readings.py device-connection-string.txt pi@raspberrypi.local:~/dht/
```

**4. Install the Azure SDK on the Pi and start sending.**

```bash
cd ~/dht
chmod 600 device-connection-string.txt
python3 -m venv .venv
.venv/bin/pip install azure-iot-device
.venv/bin/python send_readings.py
```

You should see a `Sent 22.0 C, 45.0 %` line every 30 seconds.

**5. Check the readings reached Azure.** The hub writes a blob about once a minute,
so wait a couple of minutes. Run this from this folder on your own machine.

```bash
source variables.sh
KEY=$(az storage account keys list -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT_NAME" --query '[0].value' -o tsv | tr -d '\r')
az storage blob list --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$KEY" \
  --container-name "$STORAGE_CONTAINER_NAME" --query '[].name' -o tsv
```

To see the contents, open the storage account in the Azure portal, then
**Storage browser > Blob containers > readings**, and open one of the `.json` blobs.
Each line is one message. The reading itself is in the `Body` field. If it looks like
random text instead of JSON, the body was stored base64-encoded.

## Remove

```bash
./remove.sh                  # shows what will be deleted, asks for 'yes'
./remove.sh --dry-run        # print the commands only
```

The resource group (`RESOURCE_GROUP` in `variables.sh`, here
`rg-poc-iot-southcentralus-001`) is kept. It holds other people's resources, so never delete it.

Stop `send_readings.py` on the Pi first. It can't connect once the hub is gone.

## Cost notes

- **IoT Hub F1 is free** and allows 8,000 messages a day. One reading every 30 seconds is 2,880 a day.
- A subscription can only have one F1 hub. If yours already has one, set `IOT_HUB_SKU="S1"` in `variables.sh`. S1 bills per month for as long as the hub exists, whether or not the Pi is sending, so check the [pricing page](https://azure.microsoft.com/en-us/pricing/details/iot-hub/) first and remove the hub when you're done.
- **Storage** costs pennies at this volume. Each reading is about 200 bytes.
- Nothing in this POC bills by the hour.
