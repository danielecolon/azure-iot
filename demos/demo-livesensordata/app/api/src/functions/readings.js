// GET /api/readings?minutes=30 - the N minutes of DHT11 readings that end at
// the latest reading (not at the current time). If the last reading was at
// 10:18 and it is now 10:22, minutes=5 returns 10:13 to 10:18.
//
// demo-dht's IoT Hub writes the readings to Blob Storage, one blob per batch
// (about once a minute), named:
//   <hub>/<partition>/<YYYY>/<MM>/<DD>/<HH>/<mm>.json
// Each line in a blob is one message, with the reading in its "Body" field.
//
// This function first finds the newest blob (walking hour folders back from
// now, up to LATEST_SEARCH_MINUTES), takes the newest reading in it as the end
// of the window, then lists only the hour folders that overlap the window, downloads
// blobs it hasn't seen before (kept in memory between calls), and returns the
// readings sorted by time. Long windows are averaged into at most MAX_POINTS
// points so the response stays small. It uses plain HTTPS + a SAS token.
const { app } = require("@azure/functions");

const CONTAINER_URL = (process.env.READINGS_CONTAINER_URL || "").replace(/\/$/, "");
const SAS = (process.env.READINGS_SAS || "").replace(/^\?/, "");
const PREFIX = (process.env.READINGS_PREFIX || "").replace(/\/$/, "");
const DEFAULT_MINUTES = Number(process.env.WINDOW_MINUTES) || 30;

// The time ranges the page offers. Anything else falls back to the default.
const ALLOWED_MINUTES = [1, 5, 15, 30, 60, 1440];
const MAX_MINUTES = Math.max(...ALLOWED_MINUTES);

// How far back from now to look for the latest reading. Older than this
// counts as "no readings".
const LATEST_SEARCH_MINUTES = 24 * 60;

// More readings than this are averaged into time buckets.
const MAX_POINTS = 600;

// A batch blob is named after the minute it was written, but holds messages
// from up to a minute before that. Look a little further back to be safe.
const SLACK_MS = 2 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;

// How many blobs to download at the same time.
const DOWNLOADS_AT_ONCE = 16;

const blobCache = new Map(); // blob name -> { etag, readings }
const hourListCache = new Map(); // finished hour folder -> its blobs (they no longer change)
let partitions = null; // e.g. ["iot-.../00/", "iot-.../01/"]
let partitionsCheckedAt = 0;

const pad = (n) => String(n).padStart(2, "0");

function decodeXml(text) {
  return text
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

// List blobs (and, with a delimiter, "folders") under a prefix. Follows paging.
async function listBlobs(prefix, delimiter) {
  const blobs = [];
  const folders = [];
  let marker = "";
  do {
    const params = new URLSearchParams({ restype: "container", comp: "list", prefix });
    if (delimiter) params.set("delimiter", delimiter);
    if (marker) params.set("marker", marker);
    const res = await fetch(`${CONTAINER_URL}?${params}&${SAS}`);
    if (!res.ok) throw new Error(`Listing blobs failed: HTTP ${res.status}`);
    const xml = await res.text();
    for (const [, block] of xml.matchAll(/<Blob>([\s\S]*?)<\/Blob>/g)) {
      const name = decodeXml(/<Name>([\s\S]*?)<\/Name>/.exec(block)[1]);
      const etag = (/<Etag>([\s\S]*?)<\/Etag>/.exec(block) || [])[1] || "";
      blobs.push({ name, etag });
    }
    for (const [, name] of xml.matchAll(/<BlobPrefix>\s*<Name>([\s\S]*?)<\/Name>/g)) {
      folders.push(decodeXml(name));
    }
    marker = (/<NextMarker>([\s\S]*?)<\/NextMarker>/.exec(xml) || [])[1] || "";
  } while (marker);
  return { blobs, folders };
}

// The hub's partition folders (usually 00 and 01). Re-checked every 5 minutes.
async function getPartitions() {
  if (!partitions || Date.now() - partitionsCheckedAt > 5 * 60 * 1000) {
    partitions = (await listBlobs(`${PREFIX}/`, "/")).folders;
    partitionsCheckedAt = Date.now();
  }
  return partitions;
}

// Blobs in one hour folder. An hour that ended more than a few minutes ago
// gets no new blobs, so its listing is remembered instead of asked for again.
async function listHour(folder, hourStart, now) {
  const cached = hourListCache.get(folder);
  if (cached) return cached;
  const { blobs } = await listBlobs(folder);
  if (hourStart + HOUR_MS + SLACK_MS < now) hourListCache.set(folder, blobs);
  return blobs;
}

// The UTC time encoded in a blob name, or null if the name doesn't match.
function blobTime(name) {
  const m = /(\d{4})\/(\d{2})\/(\d{2})\/(\d{2})\/(\d{2})\.json$/.exec(name);
  return m ? Date.UTC(m[1], m[2] - 1, m[3], m[4], m[5]) : null;
}

// One message line -> { time, deviceId, temperatureC, humidityPercent } or null.
function parseLine(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return null;
  }
  let body = message.Body;
  if (typeof body === "string") {
    // Stored base64-encoded when the device didn't set the JSON content type.
    try {
      body = JSON.parse(Buffer.from(body, "base64").toString("utf8"));
    } catch {
      return null;
    }
  }
  if (!body || typeof body !== "object") return null;
  // Accept demo-dht's send_readings.py names (temperatureC, humidityPercent,
  // deviceId, timestamp) and the shorter ones other Pi scripts often use
  // (temperature, humidity, device_id). No timestamp -> when the hub got it.
  const pick = (...keys) => keys.map((k) => body[k]).find((v) => v !== undefined && v !== null && v !== "");
  const temperatureC = Number(pick("temperatureC", "temperature", "temp"));
  const humidityPercent = Number(pick("humidityPercent", "humidity"));
  const time = Date.parse(pick("timestamp", "time") || message.EnqueuedTimeUtc);
  if (!Number.isFinite(temperatureC) || !Number.isFinite(humidityPercent) || Number.isNaN(time)) {
    return null;
  }
  const deviceId = pick("deviceId", "device_id") || message.SystemProperties?.connectionDeviceId || "";
  return { time: new Date(time).toISOString(), deviceId, temperatureC, humidityPercent };
}

async function readBlob({ name, etag }) {
  const cached = blobCache.get(name);
  if (cached && cached.etag === etag) return cached.readings;
  const path = name.split("/").map(encodeURIComponent).join("/");
  const res = await fetch(`${CONTAINER_URL}/${path}?${SAS}`);
  if (!res.ok) throw new Error(`Reading a blob failed: HTTP ${res.status}`);
  const readings = (await res.text()).split(/\r?\n/).filter(Boolean).map(parseLine).filter(Boolean);
  blobCache.set(name, { etag, readings });
  return readings;
}

// Run fn over items with at most `limit` running at once.
async function mapLimited(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

// Forget anything older than the longest window before the oldest possible
// latest reading, so memory stays bounded.
function pruneCaches(now) {
  const oldest = now - (LATEST_SEARCH_MINUTES + MAX_MINUTES) * 60 * 1000 - SLACK_MS - HOUR_MS;
  for (const name of blobCache.keys()) if ((blobTime(name) ?? 0) < oldest) blobCache.delete(name);
  for (const folder of hourListCache.keys()) {
    const m = /(\d{4})\/(\d{2})\/(\d{2})\/(\d{2})\/$/.exec(folder);
    if (!m || Date.UTC(m[1], m[2] - 1, m[3], m[4]) < oldest) hourListCache.delete(folder);
  }
}

// UTC hour folder path for a time, e.g. "2026/11/13/10/".
function hourPath(t) {
  const d = new Date(t);
  return `${d.getUTCFullYear()}/${pad(d.getUTCMonth() + 1)}/${pad(d.getUTCDate())}/${pad(d.getUTCHours())}/`;
}

// Blobs in one hour (all partitions).
async function listHourAllPartitions(hourStart, now) {
  const parts = await getPartitions();
  const listings = await mapLimited(parts, DOWNLOADS_AT_ONCE, (p) => listHour(p + hourPath(hourStart), hourStart, now));
  return listings.flat();
}

// The newest reading in storage, looking back at most LATEST_SEARCH_MINUTES.
// Walks hour folders from the current one backwards and stops at the first
// hour that has blobs. Finished hours are listed once and then remembered.
async function findLatest(now) {
  const searchFrom = now - LATEST_SEARCH_MINUTES * 60 * 1000;
  const first = new Date(now);
  first.setUTCMinutes(0, 0, 0);
  for (let h = first.getTime(); h + HOUR_MS > searchFrom - SLACK_MS; h -= HOUR_MS) {
    const blobs = await listHourAllPartitions(h, now);
    if (!blobs.length) continue;
    // The newest blob(s), plus any written just before them (other partition).
    const newest = Math.max(...blobs.map((b) => blobTime(b.name) ?? 0));
    const candidates = blobs.filter((b) => (blobTime(b.name) ?? 0) >= newest - SLACK_MS);
    const readings = (await mapLimited(candidates, DOWNLOADS_AT_ONCE, readBlob)).flat();
    const valid = readings.filter((r) => Date.parse(r.time) >= searchFrom);
    if (valid.length) return valid.reduce((a, b) => (b.time > a.time ? b : a));
    // Blobs without usable readings in this hour: keep looking further back.
  }
  return null;
}

// Readings with from <= time <= to, sorted by time.
async function getReadings(from, to, now) {
  const blobFrom = from - SLACK_MS;
  const blobTo = to + SLACK_MS;

  // Hour folders (UTC) that overlap the window.
  const hours = [];
  const start = new Date(blobFrom);
  start.setUTCMinutes(0, 0, 0);
  for (let t = start.getTime(); t <= Math.min(blobTo, now); t += HOUR_MS) hours.push(t);

  const listings = await mapLimited(hours, DOWNLOADS_AT_ONCE, (h) => listHourAllPartitions(h, now));
  const blobs = listings.flat().filter((b) => {
    const t = blobTime(b.name) ?? 0;
    return t >= blobFrom && t <= blobTo;
  });

  const perBlob = await mapLimited(blobs, DOWNLOADS_AT_ONCE, readBlob);
  return perBlob
    .flat()
    .filter((r) => {
      const t = Date.parse(r.time);
      return t >= from && t <= to;
    })
    .sort((a, b) => a.time.localeCompare(b.time));
}

// Average readings into equal time buckets when there are too many to draw.
// Returns the readings unchanged (bucketSeconds 0) when they already fit.
function downsample(readings, end, minutes) {
  if (readings.length <= MAX_POINTS) return { points: readings, bucketSeconds: 0 };
  const bucketMs = Math.ceil((minutes * 60 * 1000) / MAX_POINTS / 1000) * 1000;
  const start = end - minutes * 60 * 1000;
  const buckets = new Map();
  for (const r of readings) {
    const i = Math.floor((Date.parse(r.time) - start) / bucketMs);
    const b = buckets.get(i) || { t: 0, h: 0, n: 0, deviceId: r.deviceId };
    b.t += r.temperatureC;
    b.h += r.humidityPercent;
    b.n += 1;
    buckets.set(i, b);
  }
  const points = [...buckets.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([i, b]) => ({
      time: new Date(start + i * bucketMs + bucketMs / 2).toISOString(), // middle of the bucket
      deviceId: b.deviceId,
      temperatureC: Math.round((b.t / b.n) * 10) / 10,
      humidityPercent: Math.round((b.h / b.n) * 10) / 10,
      count: b.n,
    }));
  return { points, bucketSeconds: bucketMs / 1000 };
}

app.http("readings", {
  methods: ["GET"],
  authLevel: "anonymous",
  handler: async (request, context) => {
    const headers = { "Cache-Control": "no-store" };
    if (!CONTAINER_URL || !SAS || !PREFIX) {
      return {
        status: 500,
        headers,
        jsonBody: { error: "The API isn't configured. Run the app settings step of deploy.sh." },
      };
    }
    const asked = Number(request.query.get("minutes"));
    const minutes = ALLOWED_MINUTES.includes(asked) ? asked : DEFAULT_MINUTES;
    const now = Date.now();
    try {
      // The window ends at the latest reading, not at now: storage gets
      // readings about a minute late, and the device may have stopped.
      const latest = await findLatest(now);
      const windowEnd = latest ? Date.parse(latest.time) : now;
      const windowStart = windowEnd - minutes * 60 * 1000;
      const readings = latest ? await getReadings(windowStart, windowEnd, now) : [];
      pruneCaches(now);
      const { points, bucketSeconds } = downsample(readings, windowEnd, minutes);
      return {
        headers,
        jsonBody: {
          windowMinutes: minutes,
          windowStart: new Date(windowStart).toISOString(),
          windowEnd: new Date(windowEnd).toISOString(), // = latest.time, or now when there are no readings
          generatedAt: new Date(now).toISOString(),
          readingCount: readings.length,
          bucketSeconds, // 0 = raw readings, otherwise each point averages this many seconds
          latest,
          readings: points,
        },
      };
    } catch (error) {
      context.error(error); // the message never includes the SAS token
      return { status: 502, headers, jsonBody: { error: "Couldn't read the readings from storage." } };
    }
  },
});

// Exported for local testing only.
module.exports = { parseLine, blobTime, downsample };
