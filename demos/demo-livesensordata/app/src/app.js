// Live Sensor Data - polls /api/readings every 5 seconds and redraws.
(() => {
  "use strict";

  const REFRESH_MS = 10000;
  const STALE_AFTER_MS = 3 * 60 * 1000; // the hub writes to storage about every 60 s
  const RANGE_KEY = "livesensordata.range";
  const COLORS = { temp: "#3b8cf0", hum: "#1fa874", panel: "#0f1e3a", ink2: "#b9c6dc", grid: "rgba(185,198,220,0.12)" };

  // Per time range: the label used in text, and the spacing of the x-axis ticks.
  const RANGES = {
    1: { label: "1 minute", tick: 10 * 1000, seconds: true },
    5: { label: "5 minutes", tick: 60 * 1000 },
    15: { label: "15 minutes", tick: 3 * 60 * 1000 },
    30: { label: "30 minutes", tick: 5 * 60 * 1000 },
    60: { label: "1 hour", tick: 10 * 60 * 1000 },
    1440: { label: "24 hours", tick: 3 * 60 * 60 * 1000 },
  };

  const $ = (id) => document.getElementById(id);
  const timeFmt = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" });
  const timeSecFmt = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit" });

  let minutes = 30;
  let readings = [];
  let latest = null;
  let bucketSeconds = 0;
  let windowEnd = null; // time of the latest reading; the chart ends here
  let timer = null;
  let requestId = 0;

  // Remember the chosen range in this browser (optional; may be blocked).
  try {
    const saved = localStorage.getItem(RANGE_KEY);
    if (saved && RANGES[saved]) minutes = Number(saved);
  } catch {}
  $("range").value = String(minutes);

  // ---------------------------------------------------------------- chart
  // Each series gets its own truncated y-axis (not starting at 0), fitted to
  // the readings in view, so a change of 1 °C or 2 % is clearly visible.
  // minSpan stops sensor noise (DHT11: 1 °C / 1 % steps) from filling the chart.
  const AXES = { y: { minSpan: 2, fallback: [15, 30] }, y1: { minSpan: 4, fallback: [30, 60] } };

  // A "nice" tick step (1, 2 or 5 x 10^n) giving about `count` ticks.
  function niceStep(span, count = 5) {
    const raw = span / count;
    const mag = 10 ** Math.floor(Math.log10(raw));
    return [1, 2, 5, 10].map((m) => m * mag).find((s) => s >= raw);
  }

  // min/max/step for one axis from its values, padded and rounded to the step.
  function fitAxis(values, { minSpan, fallback }) {
    if (!values.length) {
      const [min, max] = fallback;
      return { min, max, step: niceStep(max - min) };
    }
    let lo = Math.min(...values);
    let hi = Math.max(...values);
    const pad = Math.max((hi - lo) * 0.15, (minSpan - (hi - lo)) / 2, 0);
    lo -= pad;
    hi += pad;
    const step = niceStep(hi - lo);
    return { min: Math.floor(lo / step) * step, max: Math.ceil(hi / step) * step, step };
  }

  const isDense = (ctx) => ctx.chart.data.datasets[ctx.datasetIndex].data.length > 120;

  const series = (label, color, yAxisID) => ({
    label,
    yAxisID,
    data: [],
    borderColor: color,
    backgroundColor: color,
    borderWidth: 2,
    // Dots like the design when points are sparse; just lines when dense
    // (hover still shows a dot and the values). Functions, so Chart.js
    // re-checks them on every redraw.
    pointRadius: (ctx) => (isDense(ctx) ? 0 : 6),
    pointHoverRadius: 12,
    pointBorderColor: COLORS.panel,
    pointBorderWidth: (ctx) => (isDense(ctx) ? 0 : 3),
    tension: 0.35,
  });

  const chart = new Chart($("chart"), {
    type: "line",
    data: { datasets: [series("Temperature (°C)", COLORS.temp, "y"), series("Humidity (%)", COLORS.hum, "y1")] },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      parsing: false,
      interaction: { mode: "nearest", axis: "x", intersect: false },
      layout: { padding: { right: 8 } },
      scales: {
        x: {
          type: "linear",
          ticks: {
            color: COLORS.ink2,
            maxRotation: 0,
            autoSkipPadding: 16,
            callback: (v) => (RANGES[minutes].seconds ? timeSecFmt : timeFmt).format(v),
          },
          // Put ticks on round clock times (e.g. 03:00, 06:00), not "exactly N ago".
          afterBuildTicks: (scale) => {
            const step = RANGES[minutes].tick;
            const tz = -new Date().getTimezoneOffset() * 60 * 1000; // local offset from UTC
            const ticks = [];
            for (let t = Math.ceil((scale.min + tz) / step) * step - tz; t <= scale.max; t += step) ticks.push({ value: t });
            scale.ticks = ticks;
          },
          grid: { display: false },
          border: { color: COLORS.grid },
        },
        // min, max and stepSize are set in render() from the data.
        y: {
          position: "left",
          title: { display: true, text: "°C", color: COLORS.temp },
          ticks: { color: COLORS.temp },
          grid: { color: COLORS.grid },
          border: { display: false },
        },
        y1: {
          position: "right",
          title: { display: true, text: "%", color: COLORS.hum },
          ticks: { color: COLORS.hum },
          grid: { display: false }, // one set of gridlines (temperature's) is enough
          border: { display: false },
        },
      },
      plugins: {
        legend: { display: false }, // HTML legend above the chart
        tooltip: {
          mode: "index",
          intersect: false,
          backgroundColor: "#1a2d52",
          borderColor: "#2a446f",
          borderWidth: 1,
          titleColor: "#f2f6fc",
          bodyColor: "#f2f6fc",
          padding: 10,
          callbacks: {
            title: (items) => {
              if (!items.length) return "";
              const t = timeSecFmt.format(items[0].parsed.x);
              return bucketSeconds ? `${t} (average)` : t;
            },
            label: (item) => ` ${item.dataset.label}: ${item.parsed.y.toFixed(item.datasetIndex === 0 || bucketSeconds ? 1 : 0)}`,
          },
        },
      },
    },
  });

  // ---------------------------------------------------------------- render
  function setStatus(kind, text) {
    $("status-dot").className = `dot ${kind}`;
    $("status-text").textContent = text;
  }

  function ago(ms) {
    const s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return `${s} s ago`;
    const m = Math.round(s / 60);
    return m < 60 ? `${m} min ago` : `${Math.round(m / 60)} h ago`;
  }

  function duration(seconds) {
    return seconds < 60 ? `${seconds} s` : `${Math.round(seconds / 60)} min`;
  }

  function render(now) {
    const range = RANGES[minutes];

    // The window ends at the latest reading (e.g. last reading 10:18, now
    // 10:22, 5 minutes -> 10:13 to 10:18). Without readings, end at now.
    const end = windowEnd ?? now;
    chart.options.scales.x.min = end - minutes * 60 * 1000;
    chart.options.scales.x.max = end;

    const points = readings.map((r) => ({ t: Date.parse(r.time), r }));
    chart.data.datasets[0].data = points.map(({ t, r }) => ({ x: t, y: r.temperatureC }));
    chart.data.datasets[1].data = points.map(({ t, r }) => ({ x: t, y: r.humidityPercent }));
    for (const [id, key] of [["y", "temperatureC"], ["y1", "humidityPercent"]]) {
      const { min, max, step } = fitAxis(readings.map((r) => r[key]), AXES[id]);
      Object.assign(chart.options.scales[id], { min, max });
      chart.options.scales[id].ticks.stepSize = step;
    }
    chart.update("none");

    $("chart").setAttribute("aria-label", `Line chart of temperature and humidity over the ${range.label} up to the last reading`);
    $("temp-value").textContent = latest ? latest.temperatureC.toFixed(1) : "—";
    $("hum-value").textContent = latest ? latest.humidityPercent.toFixed(0) : "—";
    $("empty").hidden = readings.length > 0;
    $("empty-title").textContent = latest
      ? `No readings in the ${range.label} up to the last reading`
      : "No readings in the last 24 hours";
    $("empty-hint").hidden = Boolean(latest);
    const notes = [];
    if (readings.length) notes.push("Axes don't start at zero, to show small changes");
    if (bucketSeconds) notes.push(`each point is the average of ${duration(bucketSeconds)} of readings`);
    const note = notes.join(" · ");
    $("chart-note").hidden = !note;
    $("chart-note").textContent = note && note[0].toUpperCase() + note.slice(1);

    const rows = readings.slice(-60).reverse().map((r) => {
      const tr = document.createElement("tr");
      for (const text of [timeSecFmt.format(Date.parse(r.time)), r.temperatureC.toFixed(1), r.humidityPercent.toFixed(0), r.deviceId]) {
        const td = document.createElement("td");
        td.textContent = text;
        tr.append(td);
      }
      return tr;
    });
    $("table-body").replaceChildren(...rows);
  }

  // ---------------------------------------------------------------- polling
  async function refresh() {
    clearTimeout(timer);
    const id = ++requestId;
    const asked = minutes;
    try {
      const res = await fetch(`/api/readings?minutes=${asked}`, { cache: "no-store" });
      const body = await res.json().catch(() => ({}));
      if (id !== requestId) return; // the range changed while this was loading
      if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);

      readings = body.readings || [];
      latest = body.latest || readings[readings.length - 1] || null;
      bucketSeconds = body.bucketSeconds || 0;
      windowEnd = body.windowEnd ? Date.parse(body.windowEnd) : latest ? Date.parse(latest.time) : null;
      const now = Date.now();
      render(now);
      const updated = `Updated ${timeSecFmt.format(now)} · refreshes every ${REFRESH_MS / 1000} s`;

      if (!latest) {
        setStatus("warn", `No readings in the last 24 hours · ${updated}`);
      } else {
        const age = now - Date.parse(latest.time);
        setStatus(age > STALE_AFTER_MS ? "warn" : "ok", `Last reading ${ago(age)} · ${updated}`);
      }
    } catch (error) {
      if (id !== requestId) return;
      render(Date.now()); // keep showing the last good data
      setStatus("bad", `Can't load readings (${error.message}) · retrying every ${REFRESH_MS / 1000} s`);
    }
    // Schedule the next one only after this finished, so slow responses
    // never pile up.
    if (id === requestId) timer = setTimeout(refresh, REFRESH_MS);
  }

  $("range").addEventListener("change", (event) => {
    minutes = Number(event.target.value);
    try {
      localStorage.setItem(RANGE_KEY, String(minutes));
    } catch {}
    // Clear the old range's points so they don't sit on the new axis.
    readings = [];
    bucketSeconds = 0;
    render(Date.now());
    $("empty-title").textContent = "Loading…";
    setStatus("", `Loading ${RANGES[minutes].label} up to the last reading…`);
    refresh();
  });

  refresh();
})();
