"use strict";

// OpenHarmony launcher for playwright-core: chromium.launch() on `openharmony`
// is redirected here (see patch-1-launch), which starts a browser app on the
// device with `aa start`, exposes its DevTools endpoint over hdc, and hands the
// resulting URL to playwright's own connectOverCDP path.
//
// Adapted from pzf0000/playwright-ohos@0b5de08 (ISC).

const childProcess = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const net = require("net");

const DEFAULT_TIMEOUT = 30000;
const HDC_CANDIDATES = ["/data/service/hnp/bin/hdc", "hdc"];
const OHOS_AA_FALLBACK = "/system/bin/cli_tool/executable/ohos-aa";
const DEVTOOLS_SOCKET_RE = /@(webview_devtools_remote_\d+)/;
const ARK_WEB_BUNDLE_NAME = "com.huawei.hmos.browser";

const CHANNELS = {
  huaweiBrowser: {
    bundleName: "com.huawei.hmos.browser",
    abilityName: "MainAbility",
    kind: "socket",
  },
  chrome: {
    bundleName: "com.haitai.htbrowser",
    abilityName: "EntryAbility",
    kind: "tcp",
    supportsCmdArgs: true,
  },
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Resolves with the captured output even for a non-zero-but-defined exit code,
// so callers can inspect stdout of commands hdc reports failure through.
const execFileAsync = (file, args, timeout) =>
  new Promise((resolve, reject) => {
    const options = { timeout, maxBuffer: 16 * 1024 * 1024, windowsHide: true };
    childProcess.execFile(file, args, options, (error, stdout, stderr) => {
      if (error && error.code !== 0) {
        reject(error);
        return;
      }
      resolve({
        stdout: String(stdout || ""),
        stderr: String(stderr || ""),
        code: error ? (error.code ?? 0) : 0,
      });
    });
  });

const httpGetJson = (url, timeout = 3000) =>
  new Promise((resolve, reject) => {
    const request = http.get(url, (response) => {
      let body = "";
      response.on("data", (chunk) => {
        body += chunk;
      });
      response.on("end", () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          reject(new Error(`Invalid JSON from ${url}: ${String(body).slice(0, 200)}`));
        }
      });
    });
    request.on("error", reject);
    request.setTimeout(timeout, () => request.destroy(new Error(`Timeout fetching ${url}`)));
  });

const allocateFreePort = () =>
  new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("Failed to allocate a free port"));
        return;
      }
      const { port } = address;
      server.close(() => resolve(port));
    });
    server.on("error", reject);
  });

const waitForEndpoint = async (url, timeout = DEFAULT_TIMEOUT) => {
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    try {
      await httpGetJson(url);
      return;
    } catch (error) {
      lastError = error;
      await sleep(500);
    }
  }
  throw new Error(`Endpoint ${url} did not become ready: ${lastError?.message ?? "unknown error"}`);
};

class HdcBackend {
  constructor() {
    this._forwards = [];
    this.binary = process.env.HDC_BINARY || null;
    this._binaryPromise = null;
  }

  // The harmonybrew hdc cannot reach the local device on HarmonyOS PC (it
  // answers "Connect server failed"), so probe the system one first. Probing
  // is deferred to the first command and shared between concurrent callers,
  // so constructing a backend never blocks.
  static async _probeBinary() {
    for (const candidate of HDC_CANDIDATES) {
      try {
        const { stdout } = await execFileAsync(candidate, ["list", "targets"], 10000);
        if (!stdout.includes("Connect server failed")) return candidate;
      } catch {}
    }
    return "hdc";
  }

  async _ensureBinary() {
    if (this.binary) return this.binary;
    this._binaryPromise ??= HdcBackend._probeBinary();
    this.binary = await this._binaryPromise;
    return this.binary;
  }

  async _run(args, timeout = DEFAULT_TIMEOUT) {
    return execFileAsync(await this._ensureBinary(), args, timeout);
  }

  exec(args, timeout = DEFAULT_TIMEOUT) {
    return this._run(args, timeout);
  }

  shell(command, timeout = DEFAULT_TIMEOUT) {
    return this._run(["shell", command], timeout);
  }

  async fport(local, remote) {
    const { stdout, stderr } = await this._run(["fport", local, remote]);
    if (!stdout.includes("OK")) throw new Error(`hdc fport failed: ${stdout || stderr}`);
    this._forwards.push(`${local} ${remote}`);
  }

  async fileRecv(remotePath, localPath) {
    await this._run(["file", "recv", remotePath, localPath], 60000);
  }

  async screenshot() {
    const id = `${Date.now()}-${Math.floor(Math.random() * 10000)}`;
    const remotePath = `/data/local/tmp/pw-ohos-${id}.png`;
    const localPath = path.join(os.tmpdir(), `pw-ohos-${id}.png`);
    try {
      await this.shell(`snapshot_display -f ${remotePath} -t png`);
      await this.fileRecv(remotePath, localPath);
      return await fs.promises.readFile(localPath);
    } finally {
      await this.shell(`rm -f ${remotePath}`).catch(() => {});
      await fs.promises.unlink(localPath).catch(() => {});
    }
  }

  // A falsy bundleName tears down the forwards but leaves the app running,
  // which is what reuse mode needs.
  async close(bundleName) {
    if (bundleName) await this.shell(`aa force-stop ${bundleName}`).catch(() => {});
    for (const forward of this._forwards) {
      const [local, remote] = forward.split(" ");
      await this._run(["fport", "rm", local, remote]).catch(() => {});
    }
    this._forwards.length = 0;
  }

  // Only forwards whose target socket is gone are stale: a live one may belong
  // to another session on this device. If the socket list is unreadable, remove
  // nothing rather than guess.
  async cleanupStaleForwards() {
    const unix = await this.shell("cat /proc/net/unix").catch(() => null);
    if (!unix) return;
    const live = new Set(
      (unix.stdout.match(new RegExp(DEVTOOLS_SOCKET_RE.source, "g")) || []).map((n) => n.slice(1))
    );
    const listed = await this._run(["fport", "ls"]).catch(() => ({ stdout: "", stderr: "", code: 1 }));
    for (const line of listed.stdout.split("\n")) {
      const match = line.match(/\s+(tcp:\d+)\s+(localabstract:(\S+))/);
      if (match && match[3].includes("webview_devtools_remote") && !live.has(match[3]))
        await this._run(["fport", "rm", match[1], match[2]]).catch(() => {});
    }
  }
}

const canExecute = async (binary) => {
  try {
    await execFileAsync(binary, ["--help"], 5000);
    return true;
  } catch {
    return false;
  }
};

// Falls back to `aa` over hdc shell when none of these resolve; point
// OHOS_AA_BINARY at the executable if it is only reachable as a shell alias.
const resolveOhosAa = async () => {
  const candidates = [process.env.OHOS_AA_BINARY, "ohos-aa", OHOS_AA_FALLBACK].filter(Boolean);
  for (const candidate of candidates) if (await canExecute(candidate)) return candidate;
};

const runAa = async (binary, args, timeout = DEFAULT_TIMEOUT) => {
  const { stdout, stderr } = await execFileAsync(binary, args, timeout);
  return { stdout, stderr };
};

// Everything but `channel` comes from the environment: playwright validates
// launch options against its own schema and drops unknown keys before they
// reach here. An unrecognised channel is taken to be a bundle name.
const resolveLaunchConfig = (options) => {
  const envBrowser = process.env.HARMONY_BROWSER;
  const channel = envBrowser && CHANNELS[envBrowser] ? envBrowser : (options.channel ?? "chrome");
  const preset = CHANNELS[channel];
  const config = preset
    ? { ...preset }
    : { bundleName: channel, abilityName: "MainAbility", kind: "socket" };
  if (envBrowser && !CHANNELS[envBrowser]) config.bundleName = envBrowser;
  const port = process.env.HARMONY_DEBUG_PORT ? Number(process.env.HARMONY_DEBUG_PORT) : undefined;
  if (port) config.port = port;
  config.freshBrowser = !!process.env.HARMONY_FRESH_BROWSER;
  return config;
};

// `ps -ef` columns are UID PID PPID C STIME TTY TIME CMD; matching the pid
// against the whole output instead would hit any command line that happens to
// contain those digits.
const processTable = (out) => {
  const table = new Map();
  for (const line of out.split("\n")) {
    const parts = line.trim().split(/\s+/);
    if (parts.length >= 8 && /^\d+$/.test(parts[1])) table.set(parts[1], parts.slice(7).join(" "));
  }
  return table;
};

// The socket name carries the owning pid; a socket whose process is gone
// belongs to a previous run. The browser's main process runs under the bare
// bundle name, its children under "<bundle>:render" and friends.
const findDevtoolsSocket = async (backend, config) => {
  const empty = () => ({ stdout: "", stderr: "", code: 1 });
  const pidOf = (socket) => socket.split("_").pop();
  const unix = await backend.shell("cat /proc/net/unix").catch(empty);
  const sockets = (unix.stdout.match(new RegExp(DEVTOOLS_SOCKET_RE.source, "g")) || []).map((name) =>
    name.slice(1)
  );
  if (!sockets.length) return undefined;
  const table = processTable((await backend.shell("ps -ef").catch(empty)).stdout);
  const live = sockets.filter((socket) => table.has(pidOf(socket)));
  return live.find((socket) => table.get(pidOf(socket)) === config.bundleName) ?? live[0];
};

const waitForDevtoolsSocket = async (backend, config, timeout = DEFAULT_TIMEOUT) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const socket = await findDevtoolsSocket(backend, config);
    if (socket) return socket;
    await sleep(500);
  }
  throw new Error("DevTools socket was not found on the device");
};

const isEndpointLive = async (endpoint) => {
  try {
    await httpGetJson(`${endpoint}/json/version`, 2000);
    return true;
  } catch {
    return false;
  }
};

// Returns the DevTools endpoint plus whether we started the browser ourselves —
// only then may closing the browser stop the app again.
const launchDevice = async (backend, config) => {
  const aa = await resolveOhosAa();
  await backend.cleanupStaleForwards();
  const startCommand = ["start", "--bundlename", config.bundleName, "--abilityname", config.abilityName];

  if (config.kind === "tcp") {
    // Only a browser already serving our debug port can be reused; otherwise it
    // has to restart for --remote-debugging-port to take effect.
    if (!config.freshBrowser && config.port) {
      const endpoint = `http://127.0.0.1:${config.port}`;
      if (await isEndpointLive(endpoint)) return { endpoint, started: false };
    }
    await backend.shell(`aa force-stop ${config.bundleName}`);
    const port = config.port ?? (config.supportsCmdArgs ? await allocateFreePort() : 9222);
    const args = [...startCommand];
    if (config.supportsCmdArgs)
      args.push("--ps", JSON.stringify({ cmdArgs: `--remote-debugging-port=${port}` }));
    if (aa) await runAa(aa, args);
    else if (config.supportsCmdArgs)
      await backend.shell(
        `aa start -b ${config.bundleName} -a ${config.abilityName} --ps cmdArgs '--remote-debugging-port=${port}'`
      );
    else await backend.shell(`aa start -b ${config.bundleName} -a ${config.abilityName}`);
    const endpoint = `http://127.0.0.1:${port}`;
    await waitForEndpoint(`${endpoint}/json/version`);
    return { endpoint, started: true };
  }

  // `aa start` only brings a running app to the front, so reuse needs nothing
  // beyond skipping the force-stop.
  const running = !config.freshBrowser && (await findDevtoolsSocket(backend, config)) !== undefined;
  if (!running) await backend.shell(`aa force-stop ${config.bundleName}`);
  if (aa) await runAa(aa, startCommand);
  else await backend.shell(`aa start -b ${config.bundleName} -a ${config.abilityName}`);
  const socket = await waitForDevtoolsSocket(backend, config);
  const port = await allocateFreePort();
  await backend.fport(`tcp:${port}`, `localabstract:${socket}`);
  const endpoint = `http://127.0.0.1:${port}`;
  await waitForEndpoint(`${endpoint}/json/version`);
  return { endpoint, started: !running };
};

// browser.close() must also stop the app on the device; playwright only knows
// how to tear down the CDP transport it connected over.
const stopDeviceOnBrowserClose = (browser, backend, bundleToStop) => {
  const browserProcess = browser.options?.browserProcess;
  if (!browserProcess) return;
  let stopped = false;
  const stopDevice = async () => {
    if (stopped) return;
    stopped = true;
    await backend.close(bundleToStop);
  };
  const originalClose = browserProcess.close?.bind(browserProcess);
  const originalKill = browserProcess.kill?.bind(browserProcess);
  browserProcess.close = async () => {
    try {
      await originalClose?.();
    } finally {
      await stopDevice();
    }
  };
  browserProcess.kill = async () => {
    try {
      await originalKill?.();
    } finally {
      await stopDevice();
    }
  };
};

const launchViaHdc = async (chromium, progress, options) => {
  const config = resolveLaunchConfig(options);
  const backend = new HdcBackend();
  const { endpoint, started } = await launchDevice(backend, config);
  const isArkWeb = config.bundleName === ARK_WEB_BUNDLE_NAME;
  const browser = await chromium._connectOverCDPInternal(progress, endpoint, {
    ...options,
    __ohosHdcBackend: backend,
    __ohosArkWeb: isArkWeb,
    __ohosNoDefaultContext: !isArkWeb,
  });
  browser._hdcBackend = backend;
  browser._isArkWeb = isArkWeb;
  browser._isBrowserCollocatedWithServer = false;
  stopDeviceOnBrowserClose(browser, backend, started ? config.bundleName : undefined);
  return browser;
};

const hdcScreenshot = async (backend) => backend.screenshot();

const ohosInitScript = `
(() => {
  // The device browsers expose navigator.webdriver through a getter-only
  // property, so plain assignment is ignored.
  try {
    Object.defineProperty(navigator, 'webdriver', { value: true, configurable: true });
  } catch (e) {
  }
  try {
    if (typeof Touch !== 'undefined' && Touch.prototype) {
      for (const key of ['clientX', 'clientY', 'pageX', 'pageY', 'screenX', 'screenY']) {
        const descriptor = Object.getOwnPropertyDescriptor(Touch.prototype, key);
        if (descriptor && descriptor.get) {
          Object.defineProperty(Touch.prototype, key, {
            get() {
              return Math.round(descriptor.get.call(this));
            },
            configurable: true,
          });
        }
      }
    }
  } catch (e) {
  }
})();
`;

exports.ARK_WEB_BUNDLE_NAME = ARK_WEB_BUNDLE_NAME;
exports.HdcBackend = HdcBackend;
exports.hdcScreenshot = hdcScreenshot;
exports.httpGetJson = httpGetJson;
exports.launchViaHdc = launchViaHdc;
exports.ohosInitScript = ohosInitScript;
exports.resolveLaunchConfig = resolveLaunchConfig;
exports.resolveOhosAa = resolveOhosAa;
exports.waitForEndpoint = waitForEndpoint;
