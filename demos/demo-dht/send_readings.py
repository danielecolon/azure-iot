#!/usr/bin/env python3
"""Reads a DHT11 every 30 seconds and sends each reading to Azure IoT Hub.

Runs on the Raspberry Pi. See README.md for the wiring and setup.
"""
import glob
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from azure.iot.device import IoTHubDeviceClient, Message

INTERVAL_SECONDS = 30
READ_ATTEMPTS = 5  # DHT11 reads often fail, so try a few times per reading
CONNECTION_FILE = Path(__file__).with_name("device-connection-string.txt")

# The kernel's dht11 driver (enabled by dtoverlay=dht11) publishes the sensor
# as files here. Reading them is what triggers a measurement.
SENSOR_GLOB = "/sys/bus/iio/devices/iio:device*/in_humidityrelative_input"


def find_sensor():
    matches = glob.glob(SENSOR_GLOB)
    if not matches:
        sys.exit("No DHT11 found. Is dtoverlay=dht11 set, and has the Pi rebooted?")
    return Path(matches[0]).parent


def read_sensor(sensor):
    """Returns (temperature in C, humidity in %), or None if every attempt failed."""
    for _ in range(READ_ATTEMPTS):
        try:
            # The driver reports thousandths of a degree and of a percent.
            temperature = int((sensor / "in_temp_input").read_text()) / 1000
            humidity = int((sensor / "in_humidityrelative_input").read_text()) / 1000
            return temperature, humidity
        except OSError:
            time.sleep(2)  # the sensor needs about 2 seconds between reads
    return None


def to_message(device_id, temperature, humidity):
    body = {
        "deviceId": device_id,
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "temperatureC": temperature,
        "humidityPercent": humidity,
    }
    # Without these two settings, IoT Hub stores the body in the blob as base64.
    return Message(
        json.dumps(body), content_type="application/json", content_encoding="utf-8"
    )


def main():
    sensor = find_sensor()
    connection_string = CONNECTION_FILE.read_text().strip()
    device_id = dict(
        part.split("=", 1) for part in connection_string.split(";")
    )["DeviceId"]

    client = IoTHubDeviceClient.create_from_connection_string(connection_string)
    client.connect()
    print(f"Connected as {device_id}. Press Ctrl+C to stop.", flush=True)

    try:
        while True:
            started = time.monotonic()
            reading = read_sensor(sensor)
            if reading is None:
                print("Could not read the sensor, skipping this reading.", flush=True)
            else:
                temperature, humidity = reading
                try:
                    client.send_message(to_message(device_id, temperature, humidity))
                    print(f"Sent {temperature} C, {humidity} %", flush=True)
                except Exception as error:  # keep running through network problems
                    print(f"Send failed: {error}", flush=True)
            time.sleep(max(0, INTERVAL_SECONDS - (time.monotonic() - started)))
    except KeyboardInterrupt:
        pass
    finally:
        client.shutdown()


if __name__ == "__main__":
    main()
