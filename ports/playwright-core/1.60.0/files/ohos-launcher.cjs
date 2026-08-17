"use strict";

// OpenHarmony launcher for playwright-core: chromium.launch() on `openharmony`
// is redirected here (see patch-1-launch), which starts a browser app on the
// device with `aa start`, exposes its DevTools endpoint over hdc, and hands the
// resulting URL to playwright's own connectOverCDP path.
//
// Adapted from pzf0000/playwright-ohos@40d1bba (ISC).

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

// Stability flags for browsers launched through cmdArgs; test runs should
// not be disturbed by first-run screens, sync or component updates.
const DEFAULT_CMDARGS_FLAGS = [
  "--no-first-run",
  "--disable-extensions",
  "--disable-sync",
  "--disable-default-apps",
  "--disable-background-networking",
  "--disable-component-update",
  "--no-default-browser-check",
];

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

// Resolves a command to its real filesystem path through the shell, so
// commands configured as shell aliases are found as well. `realpath $(which
// <command>)` prints the canonical path for direct commands; for aliases it
// prints one word per line of the `which` output with the aliased target as
// the last line. Existing absolute paths select the binary and filter out
// both the noise of interactive shells and the not-found output.
const resolvedCommands = new Map();
const resolveCommandPath = (command) => {
  if (resolvedCommands.has(command)) return resolvedCommands.get(command);
  // Interactive flags are needed for zsh to load rc aliases; sh has no
  // interactive alias setup and is tried first without them.
  const attempts = [["sh", "-c"], ["zsh", "-ic"], ["bash", "-ic"]];
  let resolved;
  for (const [shell, flags] of attempts) {
    try {
      const out = childProcess.execFileSync(shell, [flags, `realpath $(which ${command} 2>/dev/null) 2>/dev/null || true`], { encoding: "utf8", timeout: 8000 });
      for (const line of out.split("\n").reverse()) {
        const candidate = line.trim();
        if (candidate.startsWith("/") && fs.existsSync(candidate)) {
          resolved = candidate;
          break;
        }
      }
    } catch {}
    if (resolved) break;
  }
  resolvedCommands.set(command, resolved);
  return resolved;
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
  // which is what reuse mode needs. fallbackStop stops the app without a
  // device connection when the hdc shell fails.
  async close(bundleName, fallbackStop) {
    if (bundleName) {
      try {
        await this.shell(`aa force-stop ${bundleName}`);
      } catch {
        if (fallbackStop) await fallbackStop(bundleName).catch(() => {});
      }
    }
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

  // Connects the local wireless-debugging target when no device is connected:
  // the port is read from `param get persist.hdc.port` and the localhost
  // target is connected with `hdc tconn`. On HarmonyOS 7.1+ the ohos-aa path
  // does not need a device connection, so the caller only invokes this for
  // the HDC path.
  async ensureDeviceConnected() {
    const targets = await this._run(["list", "targets"]).catch(() => ({ stdout: "", stderr: "", code: 1 }));
    // An empty list prints "[Empty]", which is not a target.
    if (targets.stdout.replace(/\[Empty\]/g, "").trim()) return;
    const portResult = await execFileAsync("param", ["get", "persist.hdc.port"], 5000).catch(() => ({ stdout: "", stderr: "", code: 1 }));
    const port = portResult.stdout.trim();
    if (!/^\d+$/.test(port))
      throw new Error(`cannot determine the wireless debugging port (param get persist.hdc.port returned: ${JSON.stringify(port)})`);
    await this._run(["tconn", `127.0.0.1:${port}`]);
    const after = await this._run(["list", "targets"]);
    if (!after.stdout.trim())
      throw new Error(`hdc tconn 127.0.0.1:${port} did not connect; enable wireless debugging on the device first`);
  }
}

const isExecutable = (binary) => {
  try {
    childProcess.execFileSync(binary, ["--help"], { stdio: "ignore", timeout: 5000 });
    return true;
  } catch {
    return false;
  }
};

// ohos-aa starts abilities without developer mode on HarmonyOS 7.1+; on some
// machines it is only a shell alias, so resolution goes through the shell.
// OHOS_AA_BINARY overrides the search. Cached for the process lifetime.
let cachedOhosAa = null;
const resolveOhosAa = () => {
  if (cachedOhosAa !== null) return cachedOhosAa;
  const candidates = [process.env.OHOS_AA_BINARY, resolveCommandPath("ohos-aa"), OHOS_AA_FALLBACK].filter(Boolean);
  cachedOhosAa = candidates.find(isExecutable);
  return cachedOhosAa;
};

// `channel` and the harmony* launch options (registered in the launch schema
// by patch-1g) select the browser; environment variables cover older
// playwright-core that strips unknown keys. An unrecognised channel is taken
// to be a bundle name.
const resolveLaunchConfig = (options) => {
  const envBrowser = process.env.HARMONY_BROWSER;
  const ability = options.harmonyAbility ?? process.env.HARMONY_ABILITY;
  const launchUrl = options.harmonyLaunchUrl ?? process.env.HARMONY_LAUNCH_URL;
  const custom = options.harmonyBundleName || (envBrowser && !CHANNELS[envBrowser] ? envBrowser : undefined);
  const channel = envBrowser && CHANNELS[envBrowser] ? envBrowser : (options.channel ?? "chrome");
  const preset = CHANNELS[channel];
  const config = preset
    ? { ...preset }
    : { bundleName: channel, abilityName: "MainAbility", kind: "socket" };
  if (custom) config.bundleName = custom;
  if (ability) config.abilityName = ability;
  if (launchUrl) config.launchUrl = launchUrl;
  if (options.harmonyArgs?.length) config.extraArgs = options.harmonyArgs;
  const port = options.harmonyDebugPort ?? (process.env.HARMONY_DEBUG_PORT ? Number(process.env.HARMONY_DEBUG_PORT) : undefined);
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

// The installed-bundle list is queried once per process: querying `bm` on
// every launch stalls under test load and its failures must not block the
// launch (a failed query means "unknown", not "missing").
let installedBundlesCache = null;
const assertBrowserInstalled = async (backend, bundleName) => {
  if (installedBundlesCache === null) {
    const result = await backend.shell("bm dump -a").catch(() => ({ stdout: "", stderr: "", code: 1 }));
    // hdc reports shell failures as "[Fail]..." text with exit code 0, which
    // means "unknown", not "not installed".
    installedBundlesCache = result.code === 0 && !result.stdout.includes("[Fail]") ? result.stdout : "";
  }
  if (installedBundlesCache && !installedBundlesCache.includes(bundleName))
    throw new Error(`browser ${bundleName} is not installed on the device`);
};

// Transient hdc failures happen under test load; critical commands get one
// retry, cleanup commands only warn.
const hdcShellWithRetry = async (backend, command, attempts = 2) => {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await backend.shell(command);
    } catch (error) {
      if (attempt === attempts - 1) throw error;
      await sleep(1000);
    }
  }
  return { stdout: "", stderr: "", code: 1 };
};

// Best-effort cleanup: a failed force-stop under load must not block the
// launch, aa start brings the browser up regardless. ohos-aa force-stops the
// browser without a device connection.
const forceStop = async (backend, config, ohosAa) => {
  await backend.shell(`aa force-stop ${config.bundleName}`).catch(async (error) => {
    console.warn(`[playwright-ohos] force-stop ${config.bundleName} failed: ${String(error.message).slice(0, 100)}`);
    if (ohosAa) await execFileAsync(ohosAa, ["force-stop", "--bundlename", config.bundleName]).catch(() => {});
  });
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
  if (process.env.PW_OHOS_DEBUG === "1") console.log(`[playwright-ohos] launch config: ${JSON.stringify(config)}`);
  const ohosAa = resolveOhosAa();
  // The socket path always needs an HDC connection; the tcp path needs one
  // only when ohos-aa is unavailable. A failed check must not block the
  // launch: the device is usually already connected.
  if (!ohosAa || config.kind === "socket")
    await backend.ensureDeviceConnected().catch((error) => {
      console.warn(`[playwright-ohos] device connection check failed: ${String(error.message).slice(0, 100)}`);
    });
  await backend.cleanupStaleForwards();

  if (config.kind === "tcp") {
    // Only a browser already serving our debug port can be reused; otherwise it
    // has to restart for --remote-debugging-port to take effect.
    if (!config.freshBrowser && config.port) {
      const endpoint = `http://127.0.0.1:${config.port}`;
      if (await isEndpointLive(endpoint)) return { endpoint, started: false };
    }
    await assertBrowserInstalled(backend, config.bundleName);
    await forceStop(backend, config, ohosAa);
    // Browsers that accept cmdArgs pick a free local port so an occupied
    // default port never blocks the launch; fixed-port browsers use 9222.
    const port = config.port ?? (config.supportsCmdArgs ? await allocateFreePort() : 9222);
    const cmdArgs = config.supportsCmdArgs
      ? [...DEFAULT_CMDARGS_FLAGS, ...(config.extraArgs || []), `--remote-debugging-port=${port}`].join(" ")
      : "";
    // A launch URL uses the confirmed `aa start -U` path (ohos-aa --uri is
    // an implicit-startup URI and does not open the page).
    if (config.launchUrl) {
      await hdcShellWithRetry(backend, `aa start -b ${config.bundleName} -a ${config.abilityName}${cmdArgs ? ` --ps cmdArgs '${cmdArgs}'` : ""} -U ${config.launchUrl}`);
    } else if (ohosAa) {
      const startArgs = ["start", "--bundlename", config.bundleName, "--abilityname", config.abilityName];
      if (cmdArgs) startArgs.push("--ps", JSON.stringify({ cmdArgs }));
      await execFileAsync(ohosAa, startArgs);
    } else if (cmdArgs) {
      await hdcShellWithRetry(backend, `aa start -b ${config.bundleName} -a ${config.abilityName} --ps cmdArgs '${cmdArgs}'`);
    } else {
      await hdcShellWithRetry(backend, `aa start -b ${config.bundleName} -a ${config.abilityName}`);
    }
    const endpoint = `http://127.0.0.1:${port}`;
    await waitForEndpoint(`${endpoint}/json/version`);
    return { endpoint, started: true };
  }

  // `aa start` only brings a running app to the front, so reuse needs nothing
  // beyond skipping the force-stop.
  const running = !config.freshBrowser && (await findDevtoolsSocket(backend, config)) !== undefined;
  if (!running) {
    await assertBrowserInstalled(backend, config.bundleName);
    await forceStop(backend, config, ohosAa);
  }
  if (config.launchUrl) {
    await hdcShellWithRetry(backend, `aa start -b ${config.bundleName} -a ${config.abilityName} -U ${config.launchUrl}`);
  } else if (ohosAa) {
    await execFileAsync(ohosAa, ["start", "--bundlename", config.bundleName, "--abilityname", config.abilityName]);
  } else {
    await hdcShellWithRetry(backend, `aa start -b ${config.bundleName} -a ${config.abilityName}`);
  }
  const socket = await waitForDevtoolsSocket(backend, config);
  const port = await allocateFreePort();
  await backend.fport(`tcp:${port}`, `localabstract:${socket}`);
  const endpoint = `http://127.0.0.1:${port}`;
  await waitForEndpoint(`${endpoint}/json/version`);
  return { endpoint, started: !running };
};

// browser.close() must also stop the app on the device; playwright only knows
// how to tear down the CDP transport it connected over. A falsy bundleToStop
// (reused browser) only removes the port forwards.
const stopDeviceOnBrowserClose = (browser, backend, bundleToStop) => {
  const browserProcess = browser.options?.browserProcess;
  if (!browserProcess) return;
  let stopped = false;
  const stopDevice = async () => {
    if (stopped) return;
    stopped = true;
    const ohosAa = resolveOhosAa();
    const fallbackStop = ohosAa ? (bundle) => execFileAsync(ohosAa, ["force-stop", "--bundlename", bundle]) : undefined;
    await backend.close(bundleToStop, fallbackStop);
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

// Polls the device process table and closes the browser connection when the
// device browser died, so playwright emits `disconnected` instead of hanging
// on a dead session. Opt-in through PW_OHOS_CRASH_WATCH=1: the periodic hdc
// shell calls add device traffic and overlap unless guarded, which disturbed
// the ArkWeb debug channel during validation, so the watcher stays off by
// default.
const startCrashWatcher = (backend, browser, config) => {
  if (process.env.PW_OHOS_CRASH_WATCH !== "1") return;
  let stopped = false;
  let polling = false;
  const timer = setInterval(async () => {
    if (stopped || polling) return;
    polling = true;
    try {
      const result = await backend.shell(`ps -ef | grep ${config.bundleName} | grep -v grep`).catch(() => ({ stdout: "", stderr: "", code: 1 }));
      if (result.stdout.trim()) return;
      stopped = true;
      clearInterval(timer);
      console.error(`[playwright-ohos] device browser ${config.bundleName} died; closing the connection`);
      await browser._connection?.close().catch(() => {});
    } catch {
    } finally {
      polling = false;
    }
  }, 10000);
  timer.unref?.();
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
  // The collocated flag was renamed in playwright-core 1.61; set both.
  browser._isCollocatedWithServer = false;
  browser._isBrowserCollocatedWithServer = false;
  stopDeviceOnBrowserClose(browser, backend, started ? config.bundleName : undefined);
  startCrashWatcher(backend, browser, config);
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
  // The device browsers fire contextmenu on mouse release, while desktop
  // chromium fires it on press. Synthesize it on press and suppress the
  // native one so the event fires exactly once.
  try {
    document.addEventListener('contextmenu', event => {
      if (event.isTrusted) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    }, { capture: true });
    document.addEventListener('mousedown', event => {
      if (event.button !== 2 || event.defaultPrevented) {
        return;
      }
      setTimeout(() => {
        event.target.dispatchEvent(new MouseEvent('contextmenu', {
          bubbles: true,
          cancelable: true,
          button: 2,
          view: window,
          clientX: event.clientX,
          clientY: event.clientY,
        }));
      }, 0);
    }, true);
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
