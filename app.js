const storageKey = "token-monitor.entries";
const settingsKey = "token-monitor.settings";
const mirrorKey = "token-monitor.mirror";

const prices = {
  claude: 3,
  "gpt-5": 2,
  "gpt-5-mini": 0.4,
  custom: 2,
};

const form = document.querySelector("#entryForm");
const modelInput = document.querySelector("#modelInput");
const inputTokens = document.querySelector("#inputTokens");
const outputTokens = document.querySelector("#outputTokens");
const priceInput = document.querySelector("#priceInput");
const noteInput = document.querySelector("#noteInput");
const entriesEl = document.querySelector("#entries");
const emptyState = document.querySelector("#emptyState");
const totalTokensEl = document.querySelector("#totalTokens");
const totalCostEl = document.querySelector("#totalCost");
const entryCountEl = document.querySelector("#entryCount");
const lastUpdatedEl = document.querySelector("#lastUpdated");
const resetButton = document.querySelector("#resetButton");
const dailyLimit = document.querySelector("#dailyLimit");
const weeklyLimit = document.querySelector("#weeklyLimit");
const dailyReset = document.querySelector("#dailyReset");
const weeklyResetDay = document.querySelector("#weeklyResetDay");
const dailyBar = document.querySelector("#dailyBar");
const weeklyBar = document.querySelector("#weeklyBar");
const usageTooltip = document.querySelector("#usageTooltip");
const anthropicKey = document.querySelector("#anthropicKey");
const syncClaudeButton = document.querySelector("#syncClaudeButton");
const claudeSyncStatus = document.querySelector("#claudeSyncStatus");
const sessionBar = document.querySelector("#sessionBar");
const sessionPercent = document.querySelector("#sessionPercent");
const sessionResetText = document.querySelector("#sessionResetText");
const weeklyPercentLabel = document.querySelector("#weeklyPercentLabel");
const weeklyResetLabel = document.querySelector("#weeklyResetLabel");
const manualSessionPercent = document.querySelector("#manualSessionPercent");
const manualWeeklyPercent = document.querySelector("#manualWeeklyPercent");
const manualWeeklyReset = document.querySelector("#manualWeeklyReset");
let syncTimeoutId = null;

let entries = JSON.parse(localStorage.getItem(storageKey) || "[]");
const sessionStartedAt = new Date();
let mirror = JSON.parse(
  localStorage.getItem(mirrorKey) ||
    JSON.stringify({
      enabled: true,
      sessionPercent: 0,
      weeklyPercent: 7,
      weeklyReset: "Fri 12:59 AM",
      updatedAt: new Date().toISOString(),
    }),
);
let settings = JSON.parse(
  localStorage.getItem(settingsKey) ||
    JSON.stringify({
      dailyLimit: 100000,
      weeklyLimit: 700000,
      dailyReset: "00:00",
      weeklyResetDay: "1",
    }),
);

const formatter = new Intl.NumberFormat("en-US");
const currency = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 4,
});

function save() {
  localStorage.setItem(storageKey, JSON.stringify(entries));
}

function saveSettings() {
  settings = {
    dailyLimit: Number(dailyLimit.value) || 1,
    weeklyLimit: Number(weeklyLimit.value) || 1,
    dailyReset: dailyReset.value || "00:00",
    weeklyResetDay: weeklyResetDay.value || "1",
  };
  localStorage.setItem(settingsKey, JSON.stringify(settings));
}

function saveMirror() {
  mirror = {
    enabled: true,
    sessionPercent: Number(manualSessionPercent.value) || 0,
    weeklyPercent: Number(manualWeeklyPercent.value) || 0,
    weeklyReset: manualWeeklyReset.value.trim() || "Fri 12:59 AM",
    updatedAt: new Date().toISOString(),
  };
  localStorage.setItem(mirrorKey, JSON.stringify(mirror));
}

function calculateCost(entry) {
  return ((entry.input + entry.output) / 1_000_000) * entry.price;
}

function getTimeParts(value) {
  const [hours, minutes] = value.split(":").map(Number);
  return { hours: hours || 0, minutes: minutes || 0 };
}

function getDailyResetStart(now) {
  const { hours, minutes } = getTimeParts(settings.dailyReset);
  const start = new Date(now);
  start.setHours(hours, minutes, 0, 0);

  if (now < start) {
    start.setDate(start.getDate() - 1);
  }

  return start;
}

function getWeeklyResetStart(now) {
  const targetDay = Number(settings.weeklyResetDay);
  const dailyStart = getDailyResetStart(now);
  const start = new Date(dailyStart);
  const daysSinceReset = (start.getDay() - targetDay + 7) % 7;
  start.setDate(start.getDate() - daysSinceReset);
  return start;
}

function getNextReset(start, days) {
  const next = new Date(start);
  next.setDate(next.getDate() + days);
  return next;
}

function sumTokensSince(start) {
  return entries.reduce((sum, entry) => {
    const createdAt = new Date(entry.createdAt);
    if (createdAt < start) return sum;
    return sum + entry.input + entry.output;
  }, 0);
}

function formatResetTime(date) {
  const weekday = new Intl.DateTimeFormat("en-US", { weekday: "short" }).format(date);
  const time = new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
  return `${weekday} ${time}`;
}

function formatLastUpdated() {
  if (mirror.enabled && mirror.updatedAt) {
    const updatedAt = new Date(mirror.updatedAt);
    const seconds = Math.max(0, Math.floor((Date.now() - updatedAt.getTime()) / 1000));
    if (seconds < 60) return "Last updated: just now";
  }

  if (!entries.length) return "Last updated: never";

  const newest = new Date(entries[0].createdAt);
  const seconds = Math.max(0, Math.floor((Date.now() - newest.getTime()) / 1000));
  if (seconds < 60) return "Last updated: less than a minute ago";

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `Last updated: ${minutes} minute${minutes === 1 ? "" : "s"} ago`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `Last updated: ${hours} hour${hours === 1 ? "" : "s"} ago`;

  const days = Math.floor(hours / 24);
  return `Last updated: ${days} day${days === 1 ? "" : "s"} ago`;
}

function getPercent(value, limit) {
  return Math.min(100, (value / Math.max(1, limit)) * 100);
}

function renderUsage() {
  const now = new Date();
  const dailyStart = getDailyResetStart(now);
  const weeklyStart = getWeeklyResetStart(now);
  const nextDailyReset = getNextReset(dailyStart, 1);
  const nextWeeklyReset = getNextReset(weeklyStart, 7);
  const dailyTokens = sumTokensSince(dailyStart);
  const weeklyTokens = sumTokensSince(weeklyStart);
  const sessionTokens = sumTokensSince(sessionStartedAt);
  const dailyPercent = getPercent(dailyTokens, settings.dailyLimit);
  const weeklyPercent = getPercent(weeklyTokens, settings.weeklyLimit);
  const sessionPercentValue = getPercent(sessionTokens, settings.dailyLimit);
  const displaySessionPercent = mirror.enabled ? Math.min(100, Math.max(0, Number(mirror.sessionPercent) || 0)) : sessionPercentValue;
  const displayWeeklyPercent = mirror.enabled ? Math.min(100, Math.max(0, Number(mirror.weeklyPercent) || 0)) : weeklyPercent;

  dailyBar.style.width = `${displaySessionPercent}%`;
  weeklyBar.style.width = `${displayWeeklyPercent}%`;
  sessionBar.style.width = `${displaySessionPercent}%`;
  sessionPercent.textContent = `${Math.round(displaySessionPercent)}% used`;
  weeklyPercentLabel.textContent = `${Math.round(displayWeeklyPercent)}% used`;
  weeklyResetLabel.textContent = mirror.enabled ? `Resets ${mirror.weeklyReset}` : `Resets ${formatResetTime(nextWeeklyReset)}`;
  sessionResetText.textContent = sessionTokens ? `Started ${sessionStartedAt.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}` : "Starts when a message is sent";
  usageTooltip.innerHTML = "";

  window.tokenMonitorStatus = {
    dailyPercent: displaySessionPercent,
    weeklyPercent: displayWeeklyPercent,
    dailyTokens,
    weeklyTokens,
    dailyLimit: settings.dailyLimit,
    weeklyLimit: settings.weeklyLimit,
    nextDailyReset: mirror.enabled && mirror.sessionReset ? mirror.sessionReset : nextDailyReset.toLocaleString(),
    nextWeeklyReset: mirror.enabled ? mirror.weeklyReset : nextWeeklyReset.toLocaleString(),
  };
}

window.TokenMonitorStatus = () => window.tokenMonitorStatus || null;

function setClaudeSyncStatus(message, isError = false) {
  claudeSyncStatus.textContent = message;
  claudeSyncStatus.classList.toggle("is-error", isError);
  lastUpdatedEl.textContent = message;
}

function setRefreshBusy(isBusy) {
  syncClaudeButton.disabled = isBusy;
  syncClaudeButton.textContent = isBusy ? "…" : "↻";
  if (isBusy) {
    lastUpdatedEl.textContent = "Reading Claude Desktop usage...";
  }
}

function getUsageWindow() {
  const now = new Date();
  const weeklyStart = getWeeklyResetStart(now);
  return {
    startIso: weeklyStart.toISOString(),
    endIso: now.toISOString(),
  };
}

function importClaudeUsage(importedEntries, meta = {}) {
  const normalizedEntries = importedEntries.map((entry) => ({
    id: entry.id || `claude-${entry.createdAt}-${entry.input}-${entry.output}`,
    model: entry.model || "claude",
    input: Number(entry.input) || 0,
    output: Number(entry.output) || 0,
    price: Number(entry.price) || prices.claude,
    note: entry.note || "Claude API usage",
    createdAt: entry.createdAt || new Date().toISOString(),
    source: "claude-api-sync",
  }));
  const ids = new Set(entries.map((entry) => entry.id));
  const freshEntries = normalizedEntries.filter((entry) => !ids.has(entry.id));

  entries = [...freshEntries, ...entries].sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  mirror.enabled = false;
  localStorage.setItem(mirrorKey, JSON.stringify(mirror));
  save();
  render();

  const count = freshEntries.length;
  const detail = meta.message ? ` ${meta.message}` : "";
  setClaudeSyncStatus(`Synced ${count} new Claude usage entr${count === 1 ? "y" : "ies"}.${detail}`);
}

window.importClaudeUsage = importClaudeUsage;
window.reportClaudeSyncError = (message) => setClaudeSyncStatus(message, true);

async function syncClaudeUsage() {
  if (window.webkit?.messageHandlers?.claudeAppUsage) {
    setClaudeSyncStatus("Reading Claude Desktop usage...");
    setRefreshBusy(true);
    clearTimeout(syncTimeoutId);
    syncTimeoutId = setTimeout(() => {
      setRefreshBusy(false);
      setClaudeSyncStatus("Claude Desktop read timed out. Keep Claude Usage visible and try again.", true);
    }, 5000);
    window.webkit.messageHandlers.claudeAppUsage.postMessage({});
    return;
  }

  const apiKey = anthropicKey.value.trim();
  if (!apiKey) {
    mirror.updatedAt = new Date().toISOString();
    localStorage.setItem(mirrorKey, JSON.stringify(mirror));
    render();
    setClaudeSyncStatus("Refreshed mirrored Claude values.");
    return;
  }

  const usageWindow = getUsageWindow();
  setClaudeSyncStatus("Syncing Claude usage...");

  if (window.webkit?.messageHandlers?.claudeUsage) {
    window.webkit.messageHandlers.claudeUsage.postMessage({ apiKey, ...usageWindow });
    return;
  }

  await syncClaudeUsageFromBrowser(apiKey, usageWindow);
}

function applyClaudeAppUsage(usage) {
  mirror = {
    enabled: true,
    sessionPercent: Number(usage.sessionPercent) || 0,
    weeklyPercent: Number(usage.weeklyPercent) || 0,
    weeklyReset: usage.weeklyReset || mirror.weeklyReset || "Fri 12:59 AM",
    sessionReset: usage.sessionReset || "",
    updatedAt: new Date().toISOString(),
  };

  localStorage.setItem(mirrorKey, JSON.stringify(mirror));
  manualSessionPercent.value = mirror.sessionPercent;
  manualWeeklyPercent.value = mirror.weeklyPercent;
  manualWeeklyReset.value = mirror.weeklyReset;
  render();
  setClaudeSyncStatus("Read Claude Desktop usage.");
  clearTimeout(syncTimeoutId);
  setRefreshBusy(false);
}

window.applyClaudeAppUsage = applyClaudeAppUsage;

function applyClaudeDesktopTokens({ tokens, date }) {
  const id = `claude-desktop-${date}`;
  entries = entries.filter((e) => e.id !== id);
  entries.unshift({
    id,
    model: "claude",
    input: Number(tokens) || 0,
    output: 0,
    price: prices.claude,
    note: "Claude Desktop",
    createdAt: new Date(date).toISOString(),
    source: "claude-desktop-sync",
  });
  mirror.enabled = false;
  localStorage.setItem(mirrorKey, JSON.stringify(mirror));
  save();
  render();
  const formatted = new Intl.NumberFormat("en-US").format(tokens);
  setClaudeSyncStatus(`Synced Claude Desktop: ${formatted} tokens today.`);
  clearTimeout(syncTimeoutId);
  setRefreshBusy(false);
}

window.applyClaudeDesktopTokens = applyClaudeDesktopTokens;

window.reportClaudeSyncError = (message) => {
  clearTimeout(syncTimeoutId);
  setRefreshBusy(false);
  setClaudeSyncStatus(message, true);
};

async function syncClaudeUsageFromBrowser(apiKey, usageWindow) {
  const url = new URL("https://api.anthropic.com/v1/organizations/usage_report/messages");
  url.searchParams.set("starting_at", usageWindow.startIso);
  url.searchParams.set("ending_at", usageWindow.endIso);
  url.searchParams.set("bucket_width", "1d");

  try {
    const response = await fetch(url, {
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
    });

    if (!response.ok) {
      throw new Error(`Claude API returned ${response.status}`);
    }

    const payload = await response.json();
    const imported = extractClaudeUsageEntries(payload);
    importClaudeUsage(imported, { message: "Imported from Anthropic usage API." });
  } catch (error) {
    setClaudeSyncStatus(`Claude sync failed: ${error.message}`, true);
  }
}

function extractClaudeUsageEntries(payload) {
  const rows = [];

  function visit(value) {
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }

    if (!value || typeof value !== "object") return;

    const input =
      Number(value.input_tokens || 0) +
      Number(value.cache_creation_input_tokens || 0) +
      Number(value.cache_read_input_tokens || 0);
    const output = Number(value.output_tokens || 0);
    const createdAt = value.starting_at || value.start_time || value.timestamp || value.date;

    if ((input || output) && createdAt) {
      rows.push({
        id: `claude-${createdAt}-${value.model || value.model_name || "aggregate"}-${input}-${output}`,
        model: value.model || value.model_name || "claude",
        input,
        output,
        price: prices.claude,
        note: "Claude API usage",
        createdAt,
      });
    }

    Object.values(value).forEach(visit);
  }

  visit(payload);
  return rows;
}

window.extractClaudeUsageEntries = extractClaudeUsageEntries;

function render() {
  const totalTokens = entries.reduce((sum, entry) => sum + entry.input + entry.output, 0);
  const totalCost = entries.reduce((sum, entry) => sum + calculateCost(entry), 0);

  totalTokensEl.textContent = formatter.format(totalTokens);
  totalCostEl.textContent = currency.format(totalCost);
  entryCountEl.textContent = formatter.format(entries.length);
  emptyState.hidden = entries.length > 0;
  lastUpdatedEl.textContent = formatLastUpdated();

  entriesEl.innerHTML = entries
    .map((entry) => {
      const tokens = entry.input + entry.output;
      const note = entry.note || "Untitled entry";

      return `
        <article class="entry">
          <div class="entry-title">
            <strong title="${escapeHtml(note)}">${escapeHtml(note)}</strong>
            <span>${escapeHtml(entry.model)} · ${new Date(entry.createdAt).toLocaleDateString()}</span>
          </div>
          <div class="entry-stat">
            <span>Input</span>
            <strong>${formatter.format(entry.input)}</strong>
          </div>
          <div class="entry-stat">
            <span>Output</span>
            <strong>${formatter.format(entry.output)}</strong>
          </div>
          <div class="entry-stat">
            <span>Cost</span>
            <strong>${currency.format(calculateCost(entry))}</strong>
          </div>
          <button class="delete-button" type="button" data-delete="${entry.id}" title="Delete entry" aria-label="Delete entry">×</button>
        </article>
      `;
    })
    .join("");
  renderUsage();
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => {
    const entities = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#039;",
    };
    return entities[char];
  });
}

modelInput.addEventListener("change", () => {
  priceInput.value = prices[modelInput.value] ?? priceInput.value;
});

syncClaudeButton.addEventListener("click", syncClaudeUsage);
[manualSessionPercent, manualWeeklyPercent, manualWeeklyReset].forEach((input) => {
  input.addEventListener("input", () => {
    saveMirror();
    render();
  });
});
[dailyLimit, weeklyLimit, dailyReset, weeklyResetDay].forEach((input) => {
  input.addEventListener("input", () => {
    saveSettings();
    renderUsage();
  });
  input.addEventListener("change", () => {
    saveSettings();
    renderUsage();
  });
});

form.addEventListener("submit", (event) => {
  event.preventDefault();

  entries.unshift({
    id: crypto.randomUUID(),
    model: modelInput.value,
    input: Number(inputTokens.value),
    output: Number(outputTokens.value),
    price: Number(priceInput.value),
    note: noteInput.value.trim(),
    createdAt: new Date().toISOString(),
  });

  save();
  render();
  priceInput.value = prices[modelInput.value] ?? 2;
  inputTokens.value = 0;
  outputTokens.value = 0;
  noteInput.value = "";
});

entriesEl.addEventListener("click", (event) => {
  const button = event.target.closest("[data-delete]");
  if (!button) return;

  entries = entries.filter((entry) => entry.id !== button.dataset.delete);
  save();
  render();
});

resetButton.addEventListener("click", () => {
  if (!entries.length) return;
  entries = [];
  save();
  render();
});

dailyLimit.value = settings.dailyLimit;
weeklyLimit.value = settings.weeklyLimit;
dailyReset.value = settings.dailyReset;
weeklyResetDay.value = settings.weeklyResetDay;
manualSessionPercent.value = mirror.sessionPercent;
manualWeeklyPercent.value = mirror.weeklyPercent;
manualWeeklyReset.value = mirror.weeklyReset;

render();
