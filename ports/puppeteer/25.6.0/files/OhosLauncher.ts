/**
 * OhosLauncher — HarmonyOS browser launcher via ohos-aa
 *
 * launchViaOhos(): ohos-aa force-stop → ohos-aa start → waitForCdpEndpoint → CdpBrowser
 * closeCallback: Browser.close CDP → disconnected event → force-stop fallback
 *
 * Uses ohos-aa (/system/bin/cli_tool/executable/ohos-aa) for ability management.
 * Uses ohos-bm (/system/bin/cli_tool/executable/ohos-bm) for bundle info.
 * No hdc dependency for aa/bm commands.
 * ps -ef and kill are used directly (local commands).
 *
 * This file is placed at packages/puppeteer-core/src/node/OhosLauncher.ts
 * Import paths are relative to that location (same dir as BrowserLauncher.ts).
 */

import {execFileSync} from 'node:child_process';
import * as http from 'node:http';

import type {Browser, BrowserCloseCallback} from '../api/Browser.js';
import {CdpBrowser} from '../cdp/Browser.js';
import {Connection} from '../cdp/Connection.js';
import {CDPSessionEvent} from '../api/CDPSession.js';
import {NodeWebSocketTransport} from './NodeWebSocketTransport.js';
import type {LaunchOptions} from './LaunchOptions.js';

// ─── Constants ───

const OHOS_AA = '/system/bin/cli_tool/executable/ohos-aa';

const CHANNEL_MAP: Record<string, string> = {
  chrome: 'com.haitai.htbrowser',
  'chrome-beta': 'com.huawei.ohos_chromium',
};

const ABILITY_MAP: Record<string, string> = {
  'com.huawei.ohos_chromium': 'BrowserAbility',
  'com.haitai.htbrowser': 'EntryAbility',
};

const BOOL_FLAGS = [
  'disable-extensions', 'disable-default-apps',
  'disable-component-extensions-with-background-pages',
  'no-first-run', 'no-default-browser-check', 'disable-background-networking',
  'disable-client-side-phishing-detection', 'disable-popup-blocking',
  'disable-prompt-on-repost', 'disable-breakpad', 'disable-hang-monitor',
  'disable-ipc-flooding-protection', 'metrics-recording-only', 'disable-sync',
  'disable-search-engine-choice-screen', 'export-tagged-pdf',
  'disable-background-timer-throttling', 'disable-renderer-backgrounding',
  'disable-backgrounding-occluded-windows', 'disable-field-trial-config',
  'disable-component-update', 'disable-dev-shm-usage', 'no-service-autorun',
  'disable-infobars', 'allow-file-access-from-files', 'enable-automation',
  'allow-pre-commit-input', 'disable-edgeupdater',
  'edge-skip-compat-layer-relaunch', 'unsafely-disable-devtools-self-xss-warnings',
];

const DISABLED_FEATURES = [
  'AvoidUnnecessaryBeforeUnloadCheckSync', 'BoundaryEventDispatchTracksNodeRemoval',
  'DestroyProfileOnBrowserClose', 'DialMediaRouteProvider', 'GlobalMediaControls',
  'HttpsUpgrades', 'LensOverlay', 'MediaRouter', 'PaintHolding',
  'ThirdPartyStoragePartitioning', 'Translate', 'AutoDeElevate', 'RenderDocument',
  'OptimizationHints',
].join(',');

function resolveBrowserPackage(options: any): string {
  if (options.harmonyBundleName) return options.harmonyBundleName;
  if (options.channel) return CHANNEL_MAP[options.channel] || options.channel;
  const env = process.env['HARMONY_BROWSER'];
  if (env) {
    return ({chrome: 'com.huawei.ohos_chromium', haitai: 'com.haitai.htbrowser'} as any)[env] || env;
  }
  return 'com.haitai.htbrowser';
}

function resolveAbility(pkg: string): string {
  return ABILITY_MAP[pkg] || 'EntryAbility';
}

function buildLaunchParams(options: any): Record<string, any> {
  const port = options.cdpPort || options.debuggingPort || 9333;
  const args = [`--remote-debugging-port=${port}`, `--remote-allow-origins=http://127.0.0.1:${port}`];
  for (const f of BOOL_FLAGS) args.push(`--${f}`);
  args.push('--password-store=basic', '--use-mock-keychain', '--force-color-profile=srgb');
  args.push(`--disable-features=${DISABLED_FEATURES}`, '--enable-features=CDPScreenshotNewSurface');
  if (options.userDataDir) args.push(`--user-data-dir=${options.userDataDir}`);
  return {cmdArgs: args.join(' ')};
}

// ─── Command execution ───

function execCmd(cmd: string, args: string[], timeout = 30000): string {
  return execFileSync(cmd, args, {
    timeout,
    encoding: 'utf-8',
    stdio: ['pipe', 'pipe', 'pipe'],
  }).trim();
}

function execAa(args: string[], timeout = 30000): string {
  return execCmd(OHOS_AA, args, timeout);
}

// ─── Browser process management ───

/** Force-stop browser via ohos-aa, fallback to kill -9 by PID */
function forceStopBrowser(pkg: string): void {
  try {
    execAa(['force-stop', '--bundlename', pkg], 10000);
  } catch {}
  // Also kill any remaining processes by PID (handles clone processes)
  try {
    const out = execCmd('ps', ['-ef'], 5000);
    for (const line of out.split('\n')) {
      if (line.includes('grep') || !line.includes(pkg)) continue;
      const parts = line.trim().split(/\s+/);
      if (parts.length >= 2) {
        const pid = parseInt(parts[1]!, 10);
        if (pid > 0) { try { process.kill(pid, 9); } catch {} }
      }
    }
  } catch {}
}

async function waitForProcessDeath(pkg: string, timeoutMs: number): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const out = execCmd('ps', ['-ef'], 5000);
      const alive = out.split('\n').some(line => line.includes(pkg) && !line.includes('grep'));
      if (!alive) return true;
    } catch {}
    await new Promise(r => setTimeout(r, 500));
  }
  return false;
}

async function getBrowserPid(pkg: string, timeoutMs: number): Promise<number> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const out = execCmd('ps', ['-ef'], 5000);
      for (const line of out.split('\n')) {
        if (line.includes('grep') || !line.includes(pkg)) continue;
        const parts = line.trim().split(/\s+/);
        if (parts.length >= 2) {
          const pid = parseInt(parts[1]!, 10);
          if (pid > 0) return pid;
        }
      }
    } catch {}
    await new Promise(r => setTimeout(r, 500));
  }
  return 0;
}

// ─── CDP ───

function tryCdpEndpoint(url: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const req = http.get(url, (res: any) => {
      let d = '';
      res.on('data', (c: any) => d += c);
      res.on('end', () => {
        if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode}`));
        try {
          const j = JSON.parse(d);
          j.webSocketDebuggerUrl ? resolve(j.webSocketDebuggerUrl) : reject(new Error('No ws'));
        } catch {
          reject(new Error('Parse failed'));
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(2000, () => { req.destroy(); reject(new Error('Timeout')); });
  });
}

async function waitForCdpEndpoint(port: number, timeoutMs: number): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      return await tryCdpEndpoint(`http://127.0.0.1:${port}/json/version`);
    } catch {
      try {
        return await tryCdpEndpoint(`http://[::1]:${port}/json/version`);
      } catch {
        await new Promise(r => setTimeout(r, 500));
      }
    }
  }
  throw new Error(`CDP endpoint timeout on port ${port} after ${timeoutMs}ms`);
}

async function waitForBrowserReady(wsEndpoint: string, timeoutMs: number): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const t = await NodeWebSocketTransport.create(wsEndpoint, undefined, undefined as any);
      const conn = new Connection(wsEndpoint, t, 0, undefined, false, undefined, undefined as any);
      const result = await conn.send('Target.createTarget' as any, {url: 'about:blank'});
      if ((result as any).targetId) return;
    } catch {}
    await new Promise(r => setTimeout(r, 1000));
  }
}

// ─── Runtime injection ───

async function injectScripts(browser: Browser): Promise<void> {
  const pages = await browser.defaultBrowserContext().pages().catch(() => []);
  if (!pages.length) return;
  const getClient = (p: any) => typeof p._client === 'function' ? p._client() : null;
  const inject = async (src: string) => {
    for (const p of pages) {
      const c = getClient(p);
      if (c) {
        try {
          await c.send('Page.addScriptToEvaluateOnNewDocument' as any, {source: src});
        } catch {}
      }
    }
  };
  try {
    await inject('Object.defineProperty(navigator,"webdriver",{get:()=>true,configurable:true})');
  } catch {}
  try {
    await inject("if(typeof trustedTypes!=='undefined'){try{trustedTypes.createPolicy('default',{createHTML:s=>s,createScript:s=>s,createScriptURL:s=>s})}catch(e){}}");
  } catch {}
}

// ─── launchViaOhos ───

export async function launchViaOhos(
  _launcher: any,
  options: LaunchOptions = {},
): Promise<Browser> {
  const pkg = resolveBrowserPackage(options);
  const opts = options as any;
  const cdpPort = opts.cdpPort || opts.debuggingPort || 9333;
  const sandboxCloneIndex = opts.sandboxCloneIndex;

  // 1. Skip install pre-check — ohos-bm dump --all is unreliable on some devices
  //    (returns incomplete package list). Let ohos-aa start be the actual gate,
  //    consistent with patchright's approach.

  // 2. Kill existing browser
  forceStopBrowser(pkg);
  await waitForProcessDeath(pkg, 10000);

  // 3. Start fresh browser via ohos-aa
  const ability = resolveAbility(pkg);
  const wantParams = buildLaunchParams(opts);
  const aaArgs = ['start', '--bundlename', pkg, '--abilityname', ability];

  // Sandbox clone support for multi-instance
  if (sandboxCloneIndex !== undefined && sandboxCloneIndex >= 2000 && sandboxCloneIndex <= 3000) {
    aaArgs.push('--sandboxCloneIndex', String(sandboxCloneIndex));
    aaArgs.push('--creatorBundle', pkg);
  }

  // Pass Want parameters as JSON (--ps '{"cmdArgs":"..."}')
  const psJson = JSON.stringify(wantParams);
  aaArgs.push('--ps', psJson);

  if (opts.harmonyLaunchUrl) aaArgs.push('--uri', opts.harmonyLaunchUrl);

  execAa(aaArgs);

  // 4. Get PID
  const browserPid = await getBrowserPid(pkg, 10000);

  // 5. Wait for CDP endpoint
  const wsEndpoint = await waitForCdpEndpoint(cdpPort, 30000);

  // 6. Wait for browser ready
  await waitForBrowserReady(wsEndpoint, 20000);

  // 7. Create main connection
  const transport = await NodeWebSocketTransport.create(wsEndpoint, undefined, opts.logger);
  const connection = new Connection(
    wsEndpoint,
    transport,
    opts.slowMo || 0,
    opts.protocolTimeout,
    false,
    undefined,
    opts.logger,
  );

  // 8. closeCallback
  let connectionClosed = false;
  connection.once(CDPSessionEvent.Disconnected, () => { connectionClosed = true; });

  const closeCallback: BrowserCloseCallback = async () => {
    if (connection && !connectionClosed) {
      try {
        const closed = new Promise<void>(resolve => {
          connection.once(CDPSessionEvent.Disconnected, () => resolve());
        });
        await connection.closeBrowser();
        await Promise.race([
          closed,
          new Promise((_, reject) =>
            setTimeout(() => reject(new Error('Browser did not close within 5s')), 5000),
          ),
        ]);
      } catch {
        forceStopBrowser(pkg);
        await waitForProcessDeath(pkg, 10000);
      }
    } else {
      const exited = await waitForProcessDeath(pkg, 5000);
      if (!exited) {
        forceStopBrowser(pkg);
        await waitForProcessDeath(pkg, 10000);
      }
    }
  };

  // 9. mock process
  const mockProcess: any = {
    pid: browserPid,
    kill: () => { forceStopBrowser(pkg); },
    on: () => {},
  };

  // 10. defaultViewport
  const defaultViewport = opts.defaultViewport !== undefined
    ? opts.defaultViewport
    : {width: 800, height: 600};

  // 11. Create CdpBrowser
  const browser = await CdpBrowser._create(
    connection,
    [],
    opts.acceptInsecureCerts || false,
    defaultViewport,
    opts.downloadBehavior,
    mockProcess,
    closeCallback,
    opts.targetFilter,
    undefined,
    undefined,
    opts.networkEnabled ?? true,
    opts.issuesEnabled ?? true,
    opts.handleDevToolsAsPage || false,
    opts.blocklist,
    opts.allowlist,
    opts.logger,
  );

  (browser as any)._isCollocatedWithServer = false;

  // 12. Inject scripts
  await injectScripts(browser);

  // 13. Clean up about:blank pages
  const initialPages = await browser.defaultBrowserContext().pages().catch(() => []);
  for (const p of initialPages) {
    const pUrl = p.url();
    if (pUrl === 'about:blank' || pUrl === '') {
      await p.close().catch(() => {});
    }
  }

  return browser;
}
