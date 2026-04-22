import {
  AppBridge,
  PostMessageTransport,
  type McpUiHostCapabilities,
  type McpUiHostContext,
} from '@modelcontextprotocol/ext-apps/app-bridge';

interface UgotHostConfig {
  widgetHtml: string;
  widgetBaseUrl?: string | null;
  toolName?: string | null;
  toolInput?: Record<string, unknown> | null;
  toolResult?: Record<string, unknown> | null;
  toolDefinition?: Record<string, unknown> | null;
  widgetState?: Record<string, unknown> | null;
  locale?: string | null;
  theme?: 'light' | 'dark' | null;
  maxHeight?: number | null;
}

type NativePending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeout: number;
};

const IMPLEMENTATION = { name: 'ugot-mobile-mcp-apps-host', version: '0.1.0' };
const pendingNative = new Map<string, NativePending>();
let nextNativeId = 1;
let activeBridge: AppBridge | null = null;
let activeFrame: HTMLIFrameElement | null = null;

function nativeBridge() {
  return (window as any).webkit?.messageHandlers?.mcpWidget;
}

function postNative(payload: Record<string, unknown>) {
  try {
    nativeBridge()?.postMessage(payload);
  } catch (error) {
    // Keep browser/dev fallback usable.
    console.warn('[UgotMCPAppsHost] native bridge unavailable', error, payload);
  }
}

function debug(...args: unknown[]) {
  const message = args.map((value) => {
    if (typeof value === 'string') return value;
    try { return JSON.stringify(value); } catch { return String(value); }
  }).join(' ');
  console.info('[UgotMCPAppsHost]', message);
  postNative({ type: 'debug', message });
}

function requestNative(method: string, params: Record<string, unknown> = {}) {
  const id = String(nextNativeId++);
  return new Promise<unknown>((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      pendingNative.delete(id);
      reject(new Error(`Native MCP request timed out: ${method}`));
    }, 30_000);
    pendingNative.set(id, { resolve, reject, timeout });
    postNative({ type: 'mcpRequest', id, method, params });
  });
}

function resolveNative(id: string, result: unknown) {
  const pending = pendingNative.get(id);
  if (!pending) return;
  window.clearTimeout(pending.timeout);
  pendingNative.delete(id);
  pending.resolve(result ?? {});
}

function rejectNative(id: string, message: string) {
  const pending = pendingNative.get(id);
  if (!pending) return;
  window.clearTimeout(pending.timeout);
  pendingNative.delete(id);
  pending.reject(new Error(message || 'Native MCP request failed'));
}

function escapeAttribute(value: string) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

function injectBase(html: string, baseUrl?: string | null) {
  if (!baseUrl) return html;
  if (/<base\s/i.test(html)) return html;
  const baseTag = `<base href="${escapeAttribute(baseUrl)}">`;
  if (/<head[^>]*>/i.test(html)) {
    return html.replace(/<head([^>]*)>/i, `<head$1>\n${baseTag}`);
  }
  return `${baseTag}\n${html}`;
}

function readInitialConfig(): UgotHostConfig | null {
  const element = document.getElementById('ugot-mcp-config');
  const raw = element?.textContent?.trim();
  if (!raw || raw === '__UGOT_MCP_CONFIG__') return null;
  try {
    return JSON.parse(raw) as UgotHostConfig;
  } catch (error) {
    debug('config-parse-error', error instanceof Error ? error.message : String(error));
    return null;
  }
}

function currentTheme(config: UgotHostConfig): 'light' | 'dark' {
  if (config.theme === 'light' || config.theme === 'dark') return config.theme;
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function hostCapabilities(): McpUiHostCapabilities {
  return {
    openLinks: {},
    serverTools: { listChanged: false },
    serverResources: { listChanged: false },
    logging: {},
    updateModelContext: {
      text: {},
      image: {},
      audio: {},
      resource: {},
      resourceLink: {},
      structuredContent: {},
    },
    message: {
      text: {},
      image: {},
      audio: {},
      structuredContent: {},
    },
  };
}

function hostContext(config: UgotHostConfig): McpUiHostContext {
  const tool = (config.toolDefinition && typeof config.toolDefinition === 'object')
    ? config.toolDefinition
    : { name: config.toolName || 'tool', inputSchema: { type: 'object' } };
  return {
    toolInfo: { tool: tool as any },
    theme: currentTheme(config),
    locale: config.locale || navigator.language || 'ko',
    timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Seoul',
    platform: 'mobile',
    displayMode: 'inline',
    availableDisplayModes: ['inline', 'fullscreen'],
    containerDimensions: { maxHeight: config.maxHeight || 6000 },
    userAgent: navigator.userAgent,
    deviceCapabilities: { touch: true, hover: false },
  };
}

function replaceFrame(root: HTMLElement) {
  if (activeBridge) {
    try { activeBridge.close(); } catch {}
    activeBridge = null;
  }
  if (activeFrame) {
    activeFrame.remove();
    activeFrame = null;
  }

  const frame = document.createElement('iframe');
  frame.id = 'ugot-mcp-app-frame';
  frame.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox');
  frame.style.width = '100%';
  frame.style.minHeight = '360px';
  frame.style.height = '520px';
  frame.style.border = '0';
  frame.style.display = 'block';
  frame.style.background = 'transparent';
  root.replaceChildren(frame);
  activeFrame = frame;
  return frame;
}

async function mount(config: UgotHostConfig) {
  const root = document.getElementById('ugot-mcp-host-root') || document.body;
  if (!config?.widgetHtml) {
    debug('mount-missing-widget-html');
    root.textContent = '';
    return;
  }

  debug('mount-start', `htmlBytes=${config.widgetHtml.length}`, `tool=${config.toolName || ''}`);
  const frame = replaceFrame(root);
  // The widget receives its initial MCP tool input/result asynchronously after
  // the ext-app initializes. If the user can tap inside the iframe before that
  // replay finishes, a late initial tool-result can overwrite the widget's
  // newer in-app navigation state (for example: saved list -> group view ->
  // saved list again). Keep the iframe non-interactive until the initial replay
  // is either sent or safely skipped.
  frame.style.pointerEvents = 'none';
  frame.setAttribute('aria-busy', 'true');
  let lastNativeHeight = 0;
  let lastNativeWidth = 0;
  let initialReplaySettled = false;
  let appRequestedBeforeInitialReplay = false;

  const markPotentialUserIntentBeforeReplay = (kind: string) => {
    if (initialReplaySettled) return;
    appRequestedBeforeInitialReplay = true;
    debug('app-request-before-initial-replay', kind);
  };

  const enableFrameInteraction = (reason: string) => {
    frame.style.pointerEvents = 'auto';
    frame.removeAttribute('aria-busy');
    debug('frame-interaction-enabled', reason);
  };

  const applyFrameSize = (rawHeight: number, rawWidth?: number) => {
    // Evidence-mode sizing: the iframe is expanded to its measured content and
    // the native chat card grows with it. The WKWebView itself must not become
    // an inner scroll container.
    const reportedHeight = Math.ceil(Number(rawHeight) || 520);
    const nextHeight = Math.max(180, Math.min(config.maxHeight || 12_000, reportedHeight + 24));
    const nextWidth = Math.ceil(Number(rawWidth) || 0);
    frame.style.height = `${nextHeight}px`;
    root.style.minHeight = `${nextHeight}px`;
    document.documentElement.style.minHeight = `${nextHeight}px`;
    document.body.style.minHeight = `${nextHeight}px`;
    if (nextWidth > 0) frame.style.minWidth = `min(${nextWidth}px, 100%)`;
    if (Math.abs(nextHeight - lastNativeHeight) > 1 || Math.abs(nextWidth - lastNativeWidth) > 1) {
      lastNativeHeight = nextHeight;
      lastNativeWidth = nextWidth;
      debug('size-changed', `height=${nextHeight}`, `raw=${reportedHeight}`, `width=${nextWidth || ''}`);
      postNative({ type: 'sizeChanged', width: nextWidth || undefined, height: nextHeight });
    }
  };

  const measureFrameSize = () => {
    try {
      const doc = frame.contentDocument;
      const body = doc?.body;
      const html = doc?.documentElement;
      if (!body || !html) return;
      const height = Math.max(
        body.scrollHeight,
        body.offsetHeight,
        html.scrollHeight,
        html.offsetHeight,
      );
      const width = Math.max(
        body.scrollWidth,
        body.offsetWidth,
        html.scrollWidth,
        html.offsetWidth,
      );
      applyFrameSize(height, width);
    } catch (error) {
      debug('measure-size-error', error instanceof Error ? error.message : String(error));
    }
  };

  const scheduleMeasureFrameSize = () => {
    window.requestAnimationFrame(measureFrameSize);
  };

  frame.addEventListener('load', () => {
    scheduleMeasureFrameSize();
    window.setTimeout(scheduleMeasureFrameSize, 100);
    window.setTimeout(scheduleMeasureFrameSize, 500);
    window.setTimeout(scheduleMeasureFrameSize, 1500);
    try {
      const doc = frame.contentDocument;
      if (doc && typeof ResizeObserver !== 'undefined') {
        const ro = new ResizeObserver(scheduleMeasureFrameSize);
        if (doc.documentElement) ro.observe(doc.documentElement);
        if (doc.body) ro.observe(doc.body);
      }
    } catch (error) {
      debug('resize-observer-error', error instanceof Error ? error.message : String(error));
    }
  });

  const context = hostContext(config);
  const bridge = new AppBridge(null, IMPLEMENTATION, hostCapabilities(), { hostContext: context });
  activeBridge = bridge;

  bridge.oncalltool = async (params) => {
    markPotentialUserIntentBeforeReplay(`tools/call:${(params as any)?.name || ''}`);
    debug('tools-call', (params as any)?.name || '');
    return await requestNative('tools/call', params as any) as any;
  };
  bridge.onlistresources = async (params) => {
    markPotentialUserIntentBeforeReplay('resources/list');
    debug('resources-list');
    return await requestNative('resources/list', (params || {}) as any) as any;
  };
  bridge.onreadresource = async (params) => {
    markPotentialUserIntentBeforeReplay(`resources/read:${(params as any)?.uri || ''}`);
    debug('resources-read', (params as any)?.uri || '');
    return await requestNative('resources/read', params as any) as any;
  };
  if ('onlistresourcetemplates' in bridge) {
    (bridge as any).onlistresourcetemplates = async (params: any) => {
      markPotentialUserIntentBeforeReplay('resources/templates/list');
      return await requestNative('resources/templates/list', params || {}) as any;
    };
  }

  bridge.onmessage = async (params) => {
    markPotentialUserIntentBeforeReplay('message');
    debug('ui-message');
    postNative({ type: 'appMessage', message: params });
    return {};
  };
  bridge.onopenlink = async (params) => {
    markPotentialUserIntentBeforeReplay('open-link');
    debug('open-link', params.url);
    postNative({ type: 'openExternal', url: params.url });
    return {};
  };
  bridge.onloggingmessage = (params) => {
    debug('app-log', params.level || '', params.logger || '', params.data || '');
  };
  bridge.onupdatemodelcontext = async (params) => {
    markPotentialUserIntentBeforeReplay('model-context-update');
    debug('model-context-update', Object.keys(params || {}).join(','));
    postNative({ type: 'modelContext', modelContext: params });
    return {};
  };
  bridge.onrequestdisplaymode = async (params) => {
    markPotentialUserIntentBeforeReplay(`display-mode:${params.mode || ''}`);
    const mode = params.mode === 'fullscreen' ? 'fullscreen' : 'inline';
    bridge.sendHostContextChange({ displayMode: mode });
    postNative({ type: 'displayMode', mode });
    return { mode };
  };
  bridge.onsizechange = ({ width, height }) => {
    applyFrameSize(Number(height) || 520, Number(width) || undefined);
    scheduleMeasureFrameSize();
  };
  bridge.onrequestteardown = async () => ({});

  const initialized = new Promise<void>((resolve) => {
    const previous = bridge.oninitialized;
    bridge.oninitialized = (params) => {
      debug('initialized');
      resolve();
      bridge.oninitialized = previous;
      previous?.(params);
    };
  });

  await bridge.connect(new PostMessageTransport(frame.contentWindow!, frame.contentWindow!));
  frame.srcdoc = injectBase(config.widgetHtml, config.widgetBaseUrl);
  window.setTimeout(scheduleMeasureFrameSize, 100);

  void initialized.then(() => {
    const input = config.toolInput || {};
    debug('send-tool-input', Object.keys(input).join(','));
    bridge.sendToolInput({ arguments: input });
    if (appRequestedBeforeInitialReplay) {
      debug('skip-stale-initial-tool-result');
    } else if (config.toolResult && Object.keys(config.toolResult).length > 0) {
      debug('send-tool-result', Object.keys(config.toolResult).join(','));
      bridge.sendToolResult(config.toolResult as any);
    } else {
      debug('skip-empty-tool-result');
    }
    initialReplaySettled = true;
    enableFrameInteraction('initial-replay-settled');
  });

  window.setTimeout(() => {
    if (initialReplaySettled) return;
    enableFrameInteraction('initialization-timeout');
  }, 2500);

  window.setTimeout(() => {
    try {
      const doc = frame.contentDocument;
      debug('inspect', JSON.stringify({
        frameTitle: doc?.title || '',
        frameReadyState: doc?.readyState || '',
        frameText: doc?.body?.innerText?.slice(0, 300) || '',
        frameBodyLength: doc?.body?.innerHTML?.length || 0,
      }));
    } catch (error) {
      debug('inspect-error', error instanceof Error ? error.message : String(error));
    }
  }, 2500);
}

window.addEventListener('error', (event) => {
  debug('window.error', event.message, event.filename, event.lineno || 0);
});
window.addEventListener('unhandledrejection', (event) => {
  const reason = event.reason;
  debug('unhandledrejection', reason?.stack || reason?.message || String(reason));
});

const api = {
  mount,
  resolveNative,
  rejectNative,
};

(window as any).UgotMCPAppsHost = api;
(window as any).__ugotMcpResolveRequest = resolveNative;
(window as any).__ugotMcpRejectRequest = rejectNative;
(window as any).__ugotMcpResolveCall = resolveNative;
(window as any).__ugotMcpRejectCall = rejectNative;

const initialConfig = readInitialConfig();
if (initialConfig) {
  void mount(initialConfig).catch((error) => {
    debug('mount-error', error instanceof Error ? error.stack || error.message : String(error));
  });
} else {
  debug('waiting-for-config');
}
