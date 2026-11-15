# Live Sensor Data POC

A web dashboard for the temperature and humidity readings that the
[demo-dht](../demo-dht/README.md) POC collects. It's the "Live Sensor Data" screen
from the session image: two cards with the latest temperature and humidity, and a
chart of the 30 minutes up to the latest reading. The page refreshes itself every 5 seconds.

It runs on an **Azure Static Web App** (Free tier). The page is plain HTML, CSS and
JavaScript. A small API on the same app (`/api/readings`, an Azure Function that the
Static Web App manages) reads the readings from demo-dht's Blob Storage container and
returns them as JSON. A **Show** dropdown above the chart switches the time range between
1 minute, 5 minutes, 15 minutes, 30 minutes, 1 hour and 24 hours. The browser remembers the choice.

```
DHT11 → Raspberry Pi → IoT Hub → Blob Storage ──(read+list SAS)──> /api/readings → page (polls every 5 s)
           (demo-dht)                                             └──────── Static Web App ────────┘
```

This is a proof of concept. It keeps the deployment simple and skips production
practices. Shortcuts taken: the page and API are public (no sign-in), the API reads
storage with a SAS token kept in an app setting instead of a managed identity, the app
is uploaded from your machine instead of a CI/CD pipeline, and there's no IaC or monitoring.

**How "live" is it?** The page asks for new data every 5 seconds, but the Pi sends a
reading every 30 seconds and IoT Hub writes them to storage in batches about once a
minute. So new points show up on the chart about once a minute, a few at a time.

## Files

| File | What it does |
|---|---|
| `variables.sh` | The only file to edit. Subscription, location, resource group, the POC name, the 5-digit suffix, every resource name, and the names of demo-dht's storage account, container and hub. Sourced by the other scripts. |
| `deploy.sh` | Creates the Static Web App, configures it and uploads the app, as numbered steps. Prints each command before running it. |
| `remove.sh` | Deletes every resource this POC created (matched by suffix `89592`), **but keeps the resource group**. It never touches demo-dht's resources. |
| `README.md` | This file: how to run the scripts. |
| `livesensordata.md` | Background: what Static Web Apps are, when they're used, and how they're normally used in real projects. |
| `app/src/index.html`, `styles.css`, `app.js` | The page. `app.js` calls `/api/readings?minutes=<range>` every 5 seconds and redraws the cards and the chart ([Chart.js](https://www.chartjs.org/) from a CDN). |
| `app/src/staticwebapp.config.json` | Static Web App settings: runs the API on Node.js 22. |
| `app/api/src/functions/readings.js` | The API. `GET /api/readings?minutes=1\|5\|15\|30\|60\|1440` finds the latest reading (looking back up to 24 hours), lists the blobs for the N minutes that end at that reading, reads them, and returns the readings sorted by time. More than 600 readings are averaged into 600 time buckets. It keeps blobs it has already read, and the blob lists of finished hours, in memory. Accepts message bodies from demo-dht's `send_readings.py` (`temperatureC`, `humidityPercent`, `deviceId`, `timestamp`) or the shorter `temperature`, `humidity`, `device_id`. Without a timestamp, it uses the time the hub received the message. Messages with neither temperature/humidity format are skipped, which shows up as "No readings". |
| `app/api/package.json`, `host.json` | The API's npm package and Azure Functions settings. |

## Naming

Every resource is named `<type>-poc-livesensordata-89592` and tagged `pocSuffix=89592`.

| Resource | Name |
|---|---|
| Static Web App (with its managed API) | `stapp-poc-livesensordata-89592` |
| App settings (inside the app) | `READINGS_CONTAINER_URL`, `READINGS_SAS`, `READINGS_PREFIX`, `WINDOW_MINUTES` |

Read from demo-dht (not created or deleted here):

| Resource | Name |
|---|---|
| Storage account | `stpocdht93826` |
| Blob container | `readings` |
| IoT Hub (its name is the top folder of every blob) | `iot-poc-dht-93826` |

## Prerequisites

- `az login`, and the right subscription (set `SUBSCRIPTION_ID` in `variables.sh` or `az account set`)
- Permission to create resources in the resource group (and to create the RG if it doesn't exist)
- **demo-dht deployed first**, in the same resource group. If you changed its names, update the `DHT_*` values in `variables.sh`.
- Node.js 20 or later with `npm` and `npx` (to install the API's package and run the Static Web Apps CLI)
- Permission to read storage account keys on demo-dht's storage account (step 4 uses the key to sign the SAS token)

The Static Web App goes in `centralus` (`SWA_LOCATION`), because Static Web Apps
isn't offered in `southcentralus`. The resource still lives in the shared resource group.

## Deploy

```bash
./deploy.sh --list           # show the steps
./deploy.sh --steps          # pause before each step ([Enter] run, [s] skip, [q] quit)
./deploy.sh                  # run everything
./deploy.sh --from 3         # resume at step 3
./deploy.sh --only 4         # run just step 4
./deploy.sh --dry-run        # print the commands only
```

Steps:

1. Create resource group (if missing)
2. Check that demo-dht's storage account exists
3. Create the Static Web App (Free tier)
4. Give the API a read-only SAS token for the readings container
5. Install the API's npm packages locally
6. Upload the page and the API to the Static Web App

After changing anything under `app/`, upload it again with `./deploy.sh --from 5`.

## Try it

1. Start `send_readings.py` on the Pi (see [demo-dht's README](../demo-dht/README.md#try-it)).
2. Open the **Web app** URL that `deploy.sh` prints at the end
   (`https://<name>.azurestaticapps.net`). The first load can take a few seconds while the API starts.
3. Within a couple of minutes the cards show the latest reading and points appear on the chart.
   The status line at the top says how old the last reading is:
   - green dot: a reading arrived in the last 3 minutes
   - amber dot: no recent readings (is the Pi running?)
   - red dot: the page can't reach the API. It keeps the last data on screen and keeps retrying.
4. Pick a range from **Show** above the chart. For 1 hour and 24 hours, readings are averaged so the chart gets at most 600 points. A note under the chart says how many seconds or minutes each point covers. The cards always show the latest single reading. Temperature (left axis) and humidity (right axis) each have their own y-axis, fitted to the readings in view rather than starting at zero, so a change of 1 °C or a few % is easy to see. Each axis spans at least 2 °C or 4 %, so the sensor's 1-unit steps don't look like big swings.
5. **Show readings as a table** under the chart lists the newest 60 points as text.

The time range ends at the **latest reading**, not at the current time. For example, if it's 10:22 and the last reading was at 10:18, **Last 5 minutes** shows 10:13 to 10:18. So the chart never starts with an empty gap while storage catches up (it receives readings about a minute late), or after the sensor stops. The status line says how old the last reading is. If there is no reading in the last 24 hours, the chart is empty and says so.

To see what the API returns:

```bash
curl -s 'https://<name>.azurestaticapps.net/api/readings?minutes=5' | python3 -m json.tool | head -20
```

**If the page shows an error:**

| Message | Fix |
|---|---|
| `The API isn't configured` | Run `./deploy.sh --only 4`, then reload. |
| `Couldn't read the readings from storage` | The SAS token has expired (after `SAS_DAYS`, 30 by default), or demo-dht was removed and redeployed. Run `./deploy.sh --only 4`. |
| `HTTP 404` on `/api/readings` | The API wasn't uploaded. Run `./deploy.sh --from 5`. |

## Remove

```bash
./remove.sh                  # shows what will be deleted, asks for 'yes'
./remove.sh --dry-run        # print the commands only
```

The resource group (`RESOURCE_GROUP` in `variables.sh`, by default the shared
`rg-poc-southcentralus-001`) is kept. It holds other people's resources, so never delete it.

demo-dht's storage account and readings are kept too. Remove those with `../demo-dht/remove.sh`.

## Cost notes

- **Static Web Apps Free tier is free**, including the managed API. It allows 100 GB of bandwidth a month, far more than this POC needs.
- **Storage reads** cost a little while a page is open. Each refresh lists only the current hour's folder or two per hub partition, because finished hours are remembered. Only blobs the API hasn't seen before are downloaded. Switching to **24 hours** the first time downloads up to about 1,440 blobs per partition. One open page makes roughly 35,000-70,000 list operations a day, well under US$1 a day. Close the page when you're done.
- Nothing in this POC bills by the hour.
