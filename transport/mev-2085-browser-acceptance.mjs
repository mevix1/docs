import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const targetUrl = process.env.TARGET_URL ?? "http://127.0.0.1:4173/";
const evidenceDir = process.env.EVIDENCE_DIR ?? "evidence/mev-2085";
mkdirSync(evidenceDir, { recursive: true });

const chromePath = spawnSync(
  "bash",
  ["-lc", "command -v google-chrome || command -v chromium || command -v chromium-browser"],
  { encoding: "utf8" },
).stdout.trim();
if (!chromePath) throw new Error("Chromium executable not found");

const userDataDir = mkdtempSync(path.join(tmpdir(), "mev-2085-chrome-"));
const chrome = spawn(
  chromePath,
  [
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--remote-debugging-port=0",
    `--user-data-dir=${userDataDir}`,
    "about:blank",
  ],
  { stdio: ["ignore", "pipe", "pipe"] },
);
let chromeStderr = "";
chrome.stderr.on("data", (chunk) => { chromeStderr += chunk.toString(); });

async function waitForFile(file, timeoutMs = 15000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try { return readFileSync(file, "utf8"); } catch { await sleep(100); }
  }
  throw new Error(`Timed out waiting for ${file}`);
}

class Cdp {
  constructor(url) {
    this.url = url;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
  }
  async open() {
    this.ws = new WebSocket(this.url);
    await new Promise((resolve, reject) => {
      this.ws.addEventListener("open", resolve, { once: true });
      this.ws.addEventListener("error", reject, { once: true });
    });
    this.ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
        else pending.resolve(message.result ?? {});
        return;
      }
      const handlers = this.listeners.get(message.method) ?? [];
      for (const handler of handlers) handler(message.params ?? {});
    });
  }
  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  on(method, handler) {
    const handlers = this.listeners.get(method) ?? [];
    handlers.push(handler);
    this.listeners.set(method, handlers);
  }
  close() { this.ws?.close(); }
}

const cases = [];
const errors = [];
const consoleErrors = [];
const failedRequests = [];
const requests = [];
function pass(name, detail = true) { cases.push({ name, status: "PASS", detail }); }
function assert(condition, name, detail = "") {
  if (!condition) throw new Error(`${name}${detail ? `: ${detail}` : ""}`);
  pass(name, detail || true);
}

let cdp;
try {
  const active = await waitForFile(path.join(userDataDir, "DevToolsActivePort"));
  const [port] = active.trim().split(/\r?\n/);
  const target = await fetch(
    `http://127.0.0.1:${port}/json/new?${encodeURIComponent(targetUrl)}`,
    { method: "PUT" },
  ).then((response) => {
    if (!response.ok) throw new Error(`CDP target creation failed: ${response.status}`);
    return response.json();
  });
  cdp = new Cdp(target.webSocketDebuggerUrl);
  await cdp.open();
  cdp.on("Runtime.exceptionThrown", (event) => errors.push(event.exceptionDetails?.text ?? "exception"));
  cdp.on("Log.entryAdded", (event) => {
    if (event.entry?.level === "error") consoleErrors.push(event.entry.text);
  });
  cdp.on("Network.loadingFailed", (event) => failedRequests.push(event.errorText));
  cdp.on("Network.requestWillBeSent", (event) => requests.push(event.request.url));
  await Promise.all([
    cdp.send("Page.enable"),
    cdp.send("Runtime.enable"),
    cdp.send("Log.enable"),
    cdp.send("Network.enable"),
  ]);
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: 1280,
    height: 900,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await cdp.send("Page.navigate", { url: targetUrl });

  async function evaluate(expression) {
    const result = await cdp.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text ?? "evaluation failed");
    return result.result?.value;
  }
  async function waitFor(expression, timeoutMs = 15000) {
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
      if (await evaluate(expression)) return;
      await sleep(100);
    }
    throw new Error(`Timed out: ${expression}`);
  }
  async function key(key, code, windowsVirtualKeyCode) {
    await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key, code, windowsVirtualKeyCode });
    await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode });
    await sleep(100);
  }
  const findButton = (text) => `Array.from(document.querySelectorAll('button')).find((node) => node.textContent.trim() === ${JSON.stringify(text)})`;
  const findSummary = (text) => `Array.from(document.querySelectorAll('summary')).find((node) => node.textContent.trim() === ${JSON.stringify(text)})`;

  await waitFor("document.readyState === 'complete' && document.querySelector('h1')");
  await sleep(300);

  const initial = await evaluate(`(() => ({
    heading: document.querySelector('h1')?.textContent.trim(),
    body: document.body.innerText,
    diagnosticOpen: document.querySelector('.consumer-diagnostics')?.open,
    technicalOpen: document.querySelector('.consumer-technical')?.open,
    primaryTop: ${findButton("Проверить настройки")}?.getBoundingClientRect().top,
    diagnosticTop: document.querySelector('.consumer-diagnostics')?.getBoundingClientRect().top,
    scrollWidth: document.documentElement.scrollWidth,
    innerWidth,
  }))()`);
  assert(initial.heading === "Настройки ресурсов", "task heading is plain and specific", initial.heading);
  assert(!/Private package|MEV-\d+|Переключить pending|Переключить ошибку/i.test(initial.body), "internal jargon is absent from the primary screen");
  assert(initial.diagnosticOpen === false && initial.technicalOpen === false, "optional disclosures are closed by default");
  assert(initial.primaryTop < initial.diagnosticTop, "primary task precedes optional diagnostics");
  assert(initial.scrollWidth <= initial.innerWidth, "wide layout has no horizontal overflow");

  const checkboxBefore = await evaluate("document.querySelector('[role=checkbox]')?.getAttribute('aria-checked')");
  await evaluate("document.querySelector('[role=checkbox]').focus()");
  await key(" ", "Space", 32);
  const checkboxAfter = await evaluate("document.querySelector('[role=checkbox]')?.getAttribute('aria-checked')");
  assert(checkboxBefore !== checkboxAfter, "checkbox changes from the keyboard", `${checkboxBefore} -> ${checkboxAfter}`);

  const enabledRadios = await evaluate("Array.from(document.querySelectorAll('[role=radio]')).filter((node) => node.getAttribute('aria-disabled') !== 'true').length");
  assert(enabledRadios >= 2, "two enabled resource options are present", enabledRadios);
  await evaluate("Array.from(document.querySelectorAll('[role=radio]')).find((node) => node.getAttribute('aria-disabled') !== 'true').focus()");
  await key("ArrowDown", "ArrowDown", 40);
  await waitFor("document.querySelector('.selection-summary')?.textContent.includes('Общая библиотека команды')");
  pass("radio selection changes with ArrowDown");

  await evaluate(`${findButton("Проверить настройки")}.focus()`);
  await key("Enter", "Enter", 13);
  await waitFor("document.querySelector('[role=status]')?.textContent.includes('Настройки проверены локально')");
  pass("primary action has a clear local-success result");

  await evaluate(`${findSummary("Проверить дополнительные состояния")}.focus()`);
  await key("Enter", "Enter", 13);
  assert(await evaluate("document.querySelector('.consumer-diagnostics')?.open") === true, "diagnostics open from the keyboard");
  assert(await evaluate(`${findButton("Удалить выбранный вариант")} != null`) === true, "diagnostic controls are available only after disclosure");
  await evaluate(`${findButton("Удалить выбранный вариант")}.focus()`);
  await key("Enter", "Enter", 13);
  await evaluate(`${findButton("Проверить настройки")}.focus()`);
  await key("Enter", "Enter", 13);
  await waitFor("document.querySelector('[role=status]')?.textContent.includes('Не удалось проверить настройки')");
  pass("missing resource produces a clear recoverable error");

  await evaluate(`${findButton("Сбросить изменения")}.focus()`);
  await key("Enter", "Enter", 13);
  await waitFor("document.querySelector('.selection-summary')?.textContent.includes('Документы текущего проекта')");
  assert(await evaluate("document.querySelector('[role=status]')?.textContent.includes('Изменения ещё не проверены')") === true, "reset restores the initial local state");

  await evaluate(`${findSummary("О комплекте и границах")}.focus()`);
  await key("Enter", "Enter", 13);
  assert(await evaluate("document.querySelector('.consumer-technical')?.open") === true, "technical provenance opens from the keyboard");
  assert(await evaluate("document.querySelector('.consumer-technical')?.innerText.includes('Серверное сохранение')") === true, "technical boundary remains available on demand");

  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: 390,
    height: 900,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await sleep(300);
  const narrow = await evaluate(`(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    innerWidth,
    clipped: Array.from(document.querySelectorAll('button, summary, [role=radio], [role=checkbox], [role=switch]')).filter((node) => {
      const rect = node.getBoundingClientRect();
      return rect.left < -0.5 || rect.right > innerWidth + 0.5;
    }).map((node) => node.textContent?.trim() || node.getAttribute('role')),
    focused: document.activeElement?.textContent?.trim() || document.activeElement?.getAttribute('role'),
  }))()`);
  assert(narrow.scrollWidth <= narrow.innerWidth, "390px layout has no horizontal overflow", `${narrow.scrollWidth}/${narrow.innerWidth}`);
  assert(narrow.clipped.length === 0, "interactive controls remain inside the 390px viewport", narrow.clipped);

  const screenshot = await cdp.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
  writeFileSync(path.join(evidenceDir, "consumer-390.png"), Buffer.from(screenshot.data, "base64"));

  const version = await cdp.send("Browser.getVersion");
  const external = requests.filter((url) => {
    try {
      const parsed = new URL(url);
      return !["127.0.0.1", "localhost"].includes(parsed.hostname) && parsed.protocol !== "data:";
    } catch { return true; }
  });
  assert(errors.length === 0, "no page exceptions", errors);
  assert(consoleErrors.length === 0, "no console errors", consoleErrors);
  assert(failedRequests.length === 0, "no failed network requests", failedRequests);
  assert(external.length === 0, "no external browser requests", external);

  const result = {
    status: "PASS_MEV_2085_CONSUMER_BROWSER",
    targetUrl,
    browser: version.product,
    cases,
    pageErrors: errors,
    consoleErrors,
    failedRequests,
    externalRequests: external,
    boundaries: [
      "local-only settings check",
      "not backend persistence",
      "not live ChatGPT",
      "not live screen reader or IME",
      "not physical mobile/device certification",
      "not public registry release",
    ],
  };
  writeFileSync(path.join(evidenceDir, "browser-result.json"), `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result));
} catch (error) {
  const failure = {
    status: "FAIL_MEV_2085_CONSUMER_BROWSER",
    error: String(error?.stack ?? error),
    cases,
    pageErrors: errors,
    consoleErrors,
    failedRequests,
    chromeStderr: chromeStderr.slice(-4000),
  };
  writeFileSync(path.join(evidenceDir, "browser-result.json"), `${JSON.stringify(failure, null, 2)}\n`);
  console.error(JSON.stringify(failure));
  process.exitCode = 1;
} finally {
  cdp?.close();
  chrome.kill("SIGTERM");
  await sleep(200);
  rmSync(userDataDir, { recursive: true, force: true });
}
