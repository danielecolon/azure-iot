# Device telemetry with Azure IoT Hub

A small device sends sensor readings to the cloud through Azure IoT Hub, and the hub saves them to Blob Storage.

## What it is

Azure IoT Hub is a managed service that sits between devices and the cloud. Each device has its own identity, connects over an outbound encrypted link, and sends messages to the hub. The hub then decides where those messages go.

Key terms:

- **Device identity**: the hub's record of one device, with its own credentials. One device can be disabled without affecting the others.
- **Telemetry**: the stream of measurements a device sends. The formal name is device-to-cloud messages.
- **MQTT**: a lightweight messaging protocol designed for small devices. The Azure SDK uses it by default, on port 8883.
- **SAS token**: a short-lived credential signed with a secret key. It proves you hold the key without sending the key. The Azure SDK on the Pi makes these from the device key for you.
- **Message endpoint**: a destination for messages, such as a storage container. It's stored in the hub's `properties.routing.endpoints` settings.
- **Message route**: a rule that sends matching messages to an endpoint. It's stored in the hub's `properties.routing.routes` settings.
- **DHT11**: a very cheap temperature and humidity sensor. It reports whole numbers, is only moderately accurate, and its readings sometimes fail, so software should expect to retry.

## When to use it

Teams use IoT Hub when they have many devices and need per-device security, two-way communication (the cloud can also send commands to devices), and device management.

It's the wrong choice when devices are trusted applications that can send straight to a data service, or when the data is one-way and identity per device doesn't matter. In those cases Azure Event Hubs is simpler. Azure Event Grid's MQTT broker suits designs where devices publish and subscribe to each other's topics.

## How it's normally used

A typical production setup has more moving parts:

- **Provisioning**: the Device Provisioning Service registers devices automatically, usually with X.509 certificates, rather than a key copied by hand.
- **Secrets**: keys live in secure hardware on the device (a TPM or secure element), not in a text file.
- **Hot and cold paths**: messages go to a stream processor for live dashboards and alerts, and to storage for history. This POC only has the storage path.
- **Networking and access**: private endpoints limit who can reach the hub, and managed identity lets the hub write to storage without a connection string.
- **Operations**: monitoring tracks connected devices and failed messages, deployments use infrastructure as code, and device software is updated remotely.
- **Device resilience**: the program runs as a system service, restarts on failure, and buffers readings while offline.

## What this POC covers

It builds one IoT Hub on the free tier, one device identity, one route that sends every message to one storage container, and a Python script on the Pi that sends a reading every 30 seconds. The hub batches messages, so one blob usually holds a few readings, one JSON object per line.

Once a route exists, messages stop flowing to the hub's built-in endpoint. That's fine here, since storage is the only consumer, but a tool that watches the built-in endpoint won't see these readings.

It leaves out provisioning, certificates, commands sent to the device, live processing, dashboards, private networking, and running the script as a service.

## Learn more

- [What is Azure IoT Hub?](https://learn.microsoft.com/en-us/azure/iot-hub/iot-concepts-and-iot-hub)
- [Message routing and device-to-cloud messages](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-devguide-messages-d2c)
- [Choosing the right IoT Hub tier](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-scaling)
- [Authenticating with SAS tokens](https://learn.microsoft.com/en-us/azure/iot-hub/authenticate-authorize-sas)
- [IoT Hub pricing](https://azure.microsoft.com/en-us/pricing/details/iot-hub/)
