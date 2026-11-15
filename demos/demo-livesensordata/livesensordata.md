# Live dashboards with Azure Static Web Apps

A web page that shows IoT sensor readings almost as they happen, hosted on Azure
Static Web Apps with a small built-in API.

## What it is

**Azure Static Web Apps** hosts websites made of fixed files (HTML, CSS, JavaScript,
images). The files are copied to servers around the world, so pages load fast and
there's no web server for you to run. Each app gets a free HTTPS address such as
`https://<name>.azurestaticapps.net`.

Most pages also need some code that runs on a server, for example to read a database
with a secret the browser must never see. Static Web Apps covers that with a
**managed API**: Azure Functions code in an `api` folder that Azure runs for you on
the same address, under `/api/...`. Because the page and the API share one address,
the browser needs no special cross-site (CORS) settings.

Key terms:

- **Static content**: files that are sent to the browser exactly as stored.
- **Managed functions**: the API that Static Web Apps hosts for you. They only answer HTTP requests.
- **App settings**: environment variables for the API, set in Azure, never sent to the browser.
- **Deployment token**: the app's upload password. CI/CD pipelines or the SWA CLI use it to publish new versions.
- **SAS token** (shared access signature): a signed suffix for a storage URL that grants limited rights (here: read and list, on one container) until it expires.
- **Polling**: the page asks the server for new data on a timer (every 5 seconds here), instead of the server pushing it.

## When to use it

Static Web Apps fits front ends built with plain HTML or frameworks like React,
Angular, Vue or Blazor, with a light API behind them: dashboards, portals,
documentation sites, internal tools. The Free tier suits demos and personal projects.
The Standard tier adds an SLA, custom sign-in providers, private endpoints and the
option to link a full Function App instead of managed functions.

It's the wrong choice when the back end does heavy or long-running work, needs
non-HTTP triggers (queues, timers, IoT Hub events), or must keep connections open.
Then use **Azure App Service** or **Azure Container Apps** for a full web app, or link
your own **Function App** to a Standard Static Web App.

For dashboards specifically, also consider ready-made tools before writing a page:
**Power BI** (business reports), **Azure Managed Grafana** (operations dashboards over
Azure Monitor or Azure Data Explorer), or **Azure IoT Operations / Real-Time
Intelligence in Microsoft Fabric** for large device fleets.

## How it's normally used

- **Deploy from Git.** Linking the app to a GitHub or Azure DevOps repository creates a pipeline that builds and publishes on every push, with a temporary preview site for each pull request.
- **Real push instead of polling.** Live IoT dashboards usually split a **hot path** from the cold path. The hub sends each message to a stream (its built-in Event Hubs endpoint), a Function or Stream Analytics job processes it, and **Azure SignalR Service** pushes it to open browsers within a second. Storage keeps the history.
- **A query store, not raw blobs.** Readings land in a database built for time series, such as Azure Data Explorer, Cosmos DB or Azure SQL, so the API can ask for "the last 30 minutes" in one query.
- **No secrets in settings.** The API reaches storage with a **managed identity** (an Azure-issued identity with an access role), or the app gets secrets from **Key Vault**.
- **Sign-in and limits.** Built-in authentication restricts who can see the data, and the API caches results so many viewers don't multiply the storage reads.

## What this POC covers

It creates one Free-tier Static Web App with:

- a page that polls `/api/readings` every 5 seconds and draws two value cards and a chart, with a dropdown for 1 minute up to 24 hours (long ranges are averaged on the server so the response stays small), and
- a managed Azure Function that lists and reads demo-dht's batch blobs for the last 30 minutes with a read-only SAS token. It keeps blobs it already read in memory, so each refresh mostly just lists folders.

It leaves out Git-based CI/CD, sign-in, managed identity, push updates (SignalR), and
a time-series database. Because readings arrive through storage, which IoT Hub writes
about once a minute, the chart is "near live", not truly real time.

## Learn more

- [What is Azure Static Web Apps?](https://learn.microsoft.com/en-us/azure/static-web-apps/overview)
- [API support in Static Web Apps with Azure Functions](https://learn.microsoft.com/en-us/azure/static-web-apps/apis-functions)
- [Deploy with the Static Web Apps CLI](https://learn.microsoft.com/en-us/azure/static-web-apps/static-web-apps-cli-deploy)
- [Static Web Apps hosting plans](https://learn.microsoft.com/en-us/azure/static-web-apps/plans)
- [Grant limited access with shared access signatures (SAS)](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview)
- [What is Azure SignalR Service?](https://learn.microsoft.com/en-us/azure/azure-signalr/signalr-overview)
- [Static Web Apps pricing](https://azure.microsoft.com/en-us/pricing/details/app-service/static/)
