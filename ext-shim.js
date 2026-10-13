// Flint's extension API: the chrome.* / browser.* surface Chrome extensions expect, bridged to Flint
// (native) through webkit.messageHandlers.flintExt. Runs in each extension's content world (content
// scripts), in extension pages (chrome-extension://…) and, for externally_connectable sites, in the page.
(() => {
  const CFG = __FLINT_CFG__;
  const H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.flintExt;
  if (!H) return;

  // ── externally connectable web pages (e.g. account.proton.me talking to Proton Pass) ──────────────
  if (CFG.mode === 'external') {
    const ids = CFG.external[location.origin] || [];
    if (!ids.length) return;
    const ext = (op, id, args) => H.postMessage({ ext: id, op, args }).then(r => { if (r && r.__error) throw new Error(r.__error); return r; });
    const rt = (window.chrome = window.chrome || {}).runtime = window.chrome.runtime || {};
    rt.sendMessage = (id, msg, opts, cb) => {
      if (typeof opts === 'function') { cb = opts; opts = undefined; }
      const p = ext('runtime.sendMessageExternal', id, [msg]);
      if (cb) { p.then(cb, () => cb()); return; }
      return p;
    };
    rt.connect = () => { throw new Error('runtime.connect from web pages is not supported in Flint yet'); };
    return;
  }

  let ID = CFG.ext;
  if (!ID) { if (location.protocol !== 'chrome-extension:') return; ID = location.host; }
  const E = CFG.exts[ID];
  if (!E) return;
  const IS_BG = CFG.mode === 'page' && location.pathname === '/__flint_background.html';
  const IS_CONTENT = CFG.mode === 'content';
  const G = globalThis;
  if (G.__flintExtLoaded) return;
  G.__flintExtLoaded = true;

  // development only (Flint's extdebug switch): forward the extension's errors and warnings to Flint's log
  if (CFG.debug) {
    const show = x => { try { return x instanceof Error || (x && x.stack) ? String(x) + ' @ ' + String(x.stack || '').split('\n')[0] : typeof x === 'object' ? JSON.stringify(x) : String(x); } catch (e) { return String(x); } };
    const dbg = (...a) => { try { H.postMessage({ ext: ID, op: 'debug.log', args: [a.map(show).join(' ').slice(0, 600)] }); } catch (e) {} };
    const oe = console.error.bind(console), ow = console.warn.bind(console);
    console.error = (...a) => { dbg('error:', ...a); oe(...a); };
    console.warn = (...a) => { dbg('warn:', ...a); ow(...a); };
    if (G.addEventListener) {
      G.addEventListener('error', ev => dbg('uncaught:', ev.message, (ev.filename || '') + ':' + ev.lineno));
      G.addEventListener('unhandledrejection', ev => dbg('rejection:', ev.reason));
    }
    dbg('loaded', CFG.mode, location.href.slice(0, 80));
  }

  // Chrome APIs WebKit lacks that extensions take for granted
  if (!G.requestIdleCallback) {
    G.requestIdleCallback = (cb, opts) => { const start = Date.now(); return setTimeout(() => cb({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) }), 1); };
    G.cancelIdleCallback = id => clearTimeout(id);
  }

  const clone = v => (v === undefined ? null : JSON.parse(JSON.stringify(v)));
  const call = (op, args) => H.postMessage({ ext: ID, op, args: clone(args || []) }).then(r => {
    if (r && r.__error) throw new Error(r.__error);
    return r === null ? undefined : r;
  });

  const ev = () => {
    const ls = new Set();
    return {
      addListener: f => ls.add(f), removeListener: f => ls.delete(f), hasListener: f => ls.has(f), hasListeners: () => ls.size > 0,
      _ls: ls, _fire: (...a) => { for (const f of [...ls]) { try { f(...a); } catch (e) { console.error(e); } } }
    };
  };

  let lastError;
  // Chrome APIs take an optional trailing callback; without one they return a promise.
  const api = (op, map) => (...args) => {
    let cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    const p = (map ? map(...args) : call(op, args));
    if (!cb) return p;
    p.then(r => cb(r), e => { lastError = { message: String(e && e.message || e) }; try { cb(); } finally { lastError = undefined; } });
  };
  const nop = v => api(null, () => Promise.resolve(v));

  // ── runtime ────────────────────────────────────────────────────────────────────────────────────
  const onMessage = ev(), onConnect = ev(), onMessageExternal = ev(), onConnectExternal = ev();
  const onInstalled = ev(), onStartup = ev(), onSuspend = ev(), onUpdateAvailable = ev();
  const ports = new Map();

  function makePort(extId, name) {
    const id = 'p' + Math.random().toString(36).slice(2) + Date.now().toString(36);
    const port = portObject(id, name, null, extId, false);
    call('runtime.connect', [id, name]).then(ok => { if (!ok) port._disconnect(); }, () => port._disconnect());
    return port;
  }
  function portObject(id, name, sender, extId, external) {
    const onMsg = ev(), onDis = ev();
    let open = true;
    const post = external
      ? (m) => H.postMessage({ ext: extId, op: 'port.post', args: [id, clone(m)] })
      : (m) => call('port.post', [id, m]);
    const port = {
      name, sender: sender || undefined, onMessage: onMsg, onDisconnect: onDis,
      postMessage: m => { if (!open) throw new Error('Attempting to use a disconnected port object'); post(m).catch(() => {}); },
      disconnect: () => { if (!open) return; open = false; ports.delete(id); (external ? H.postMessage({ ext: extId, op: 'port.disconnect', args: [id] }) : call('port.disconnect', [id])).catch(() => {}); },
      _disconnect: () => { if (!open) return; open = false; ports.delete(id); onDis._fire(port); },
      _id: id
    };
    ports.set(id, port);
    return port;
  }
  // Native → JS entry points (called with callAsyncJavaScript)
  G.__flintOnMessage = (msg, sender, external) => new Promise(resolve => {
    const target = external ? onMessageExternal : onMessage;
    let done = false, pending = false;
    const sendResponse = r => { if (!done) { done = true; resolve(r === undefined ? null : clone(r)); } };
    for (const f of [...target._ls]) {
      let r;
      try { r = f(msg, sender, sendResponse); } catch (e) { console.error(e); }
      if (r === true) pending = true;
      else if (r && typeof r.then === 'function') { pending = true; r.then(sendResponse, e => sendResponse({ __error: String(e && e.message || e) })); }
    }
    if (!pending && !done) resolve(null);
  });
  G.__flintOnConnect = (id, name, sender, external) => {
    const port = portObject(id, name, sender, ID, false);
    (external ? onConnectExternal : onConnect)._fire(port);
    return true;
  };
  G.__flintPortEvent = (id, kind, data) => {
    const p = ports.get(id); if (!p) return false;
    if (kind === 'message') p.onMessage._fire(data, p); else p._disconnect();
    return true;
  };
  G.__flintStorageChanged = (changes, area) => { storageOnChanged._fire(changes, area); (storage[area] && storage[area].onChanged._fire(changes)); return true; };
  G.__flintTabEvent = (kind, a, b, c) => { const e = G.__flintTabEventsRef && G.__flintTabEventsRef[kind]; if (e) e._fire(a, b, c); return true; };
  G.__flintInstalled = (details) => { onInstalled._fire(details); onStartup._fire(); return true; };

  const getURL = p => `chrome-extension://${ID}/${String(p || '').replace(/^\//, '')}`;
  const runtime = {
    id: ID,
    get lastError() { return lastError; },
    getURL,
    getManifest: () => clone(E.manifest),
    getPlatformInfo: api(null, () => Promise.resolve({ os: 'mac', arch: 'x86-64', nacl_arch: 'x86-64' })),
    getBrowserInfo: api(null, () => Promise.resolve({ name: 'Chrome', vendor: 'Flint', version: '140.0', buildID: '1' })),
    sendMessage: api(null, (...a) => {
      let msg = a.length >= 2 && typeof a[0] === 'string' && a[0] === ID ? a[1] : a[0];
      return call('runtime.sendMessage', [msg]);
    }),
    connect: (a, b) => { const info = typeof a === 'object' ? a : b; return makePort(ID, (info && info.name) || ''); },
    onMessage, onConnect, onMessageExternal, onConnectExternal, onInstalled, onStartup, onSuspend, onUpdateAvailable,
    onSuspendCanceled: ev(), onRestartRequired: ev(),
    setUninstallURL: nop(undefined), requestUpdateCheck: nop({ status: 'no_update' }),
    reload: () => call('runtime.reload', []),
    openOptionsPage: api('runtime.openOptionsPage'),
    getContexts: nop([]),
    getBackgroundPage: nop(undefined)
  };

  // ── storage (shared by every part of the extension; kept by Flint on disk) ──────────────────────
  const storageOnChanged = ev();
  const area = name => ({
    get: api(null, keys => call('storage.get', [name, keys === undefined ? null : keys])),
    set: api(null, items => call('storage.set', [name, items])),
    remove: api(null, keys => call('storage.remove', [name, keys])),
    clear: api(null, () => call('storage.clear', [name])),
    getBytesInUse: nop(0),
    setAccessLevel: nop(undefined),
    getKeys: api(null, () => call('storage.get', [name, null]).then(o => Object.keys(o || {}))),
    onChanged: ev(),
    QUOTA_BYTES: 10485760
  });
  const storage = { local: area('local'), sync: area('sync'), session: area('session'), managed: area('managed'), onChanged: storageOnChanged };

  // ── i18n ────────────────────────────────────────────────────────────────────────────────────────
  const i18n = {
    getMessage: (name, subs) => {
      const m = E.messages[String(name).toLowerCase()];
      if (!m) return '';
      subs = subs === undefined ? [] : Array.isArray(subs) ? subs : [subs];
      let s = m.message || '';
      const ph = m.placeholders || {};
      s = s.replace(/\$([A-Za-z0-9_@]+)\$/g, (all, k) => { const p = ph[k.toLowerCase()] || ph[k]; return p ? p.content : all; });
      return s.replace(/\$(\d)/g, (all, n) => subs[Number(n) - 1] !== undefined ? String(subs[Number(n) - 1]) : '');
    },
    getUILanguage: () => 'en-US',
    getAcceptLanguages: api(null, () => Promise.resolve(['en-US', 'en'])),
    detectLanguage: api(null, () => Promise.resolve({ isReliable: false, languages: [] }))
  };

  const chrome = { runtime, storage, i18n };

  if (!IS_CONTENT) {
    // ── tabs / windows ────────────────────────────────────────────────────────────────────────────
    const tabEvents = { updated: ev(), activated: ev(), removed: ev(), created: ev(), replaced: ev(), highlighted: ev(), moved: ev(), attached: ev(), detached: ev() };
    G.__flintTabEventsRef = tabEvents;
    chrome.tabs = {
      TAB_ID_NONE: -1,
      query: api('tabs.query'), get: api('tabs.get'), create: api('tabs.create'), update: api('tabs.update'),
      remove: api('tabs.remove'), reload: api('tabs.reload'), getCurrent: api('tabs.getCurrent'),
      sendMessage: api(null, (tabId, msg, opts) => call('tabs.sendMessage', [tabId, msg, opts || null])),
      captureVisibleTab: nop(''), detectLanguage: nop('en'), setZoom: nop(undefined), getZoom: nop(1),
      onUpdated: tabEvents.updated, onActivated: tabEvents.activated, onRemoved: tabEvents.removed, onCreated: tabEvents.created,
      onReplaced: tabEvents.replaced, onHighlighted: tabEvents.highlighted, onMoved: tabEvents.moved, onAttached: tabEvents.attached, onDetached: tabEvents.detached
    };
    const win = { id: 1, focused: true, type: 'normal', state: 'normal', incognito: false, alwaysOnTop: false };
    chrome.windows = {
      WINDOW_ID_CURRENT: -2, WINDOW_ID_NONE: -1,
      get: nop(win), getCurrent: nop(win), getLastFocused: nop(win), getAll: nop([win]),
      create: api(null, info => call('tabs.create', [{ url: info && (Array.isArray(info.url) ? info.url[0] : info.url), active: true }]).then(t => ({ ...win, tabs: [t] }))),
      update: nop(win), remove: nop(undefined), onFocusChanged: ev(), onCreated: ev(), onRemoved: ev(), onBoundsChanged: ev()
    };
    // ── alarms (timers live in the background page) ──────────────────────────────────────────────
    const alarms = new Map();
    const alarmsOnAlarm = ev();
    G.__flintAlarmsOnAlarm = alarmsOnAlarm;
    const clearAlarm = n => { const a = alarms.get(n); if (!a) return false; clearTimeout(a.t); clearInterval(a.i); alarms.delete(n); return true; };
    chrome.alarms = {
      create: (name, info) => {
        if (typeof name === 'object') { info = name; name = ''; }
        name = name || ''; info = info || {};
        clearAlarm(name);
        const delay = info.when ? Math.max(0, info.when - Date.now()) : (info.delayInMinutes ?? info.periodInMinutes ?? 0) * 60000;
        const a = { name, scheduledTime: Date.now() + delay, periodInMinutes: info.periodInMinutes };
        const fire = () => { a.scheduledTime = Date.now() + (a.periodInMinutes || 0) * 60000; alarmsOnAlarm._fire({ name, scheduledTime: a.scheduledTime, periodInMinutes: a.periodInMinutes }); };
        a.t = setTimeout(() => { fire(); if (a.periodInMinutes) a.i = setInterval(fire, a.periodInMinutes * 60000); else alarms.delete(name); }, delay);
        alarms.set(name, a);
        return Promise.resolve();
      },
      get: api(null, n => Promise.resolve(alarms.has(n || '') ? { name: n || '', scheduledTime: alarms.get(n || '').scheduledTime, periodInMinutes: alarms.get(n || '').periodInMinutes } : undefined)),
      getAll: api(null, () => Promise.resolve([...alarms.values()].map(a => ({ name: a.name, scheduledTime: a.scheduledTime, periodInMinutes: a.periodInMinutes })))),
      clear: api(null, n => Promise.resolve(clearAlarm(n || ''))),
      clearAll: api(null, () => { for (const n of [...alarms.keys()]) clearAlarm(n); return Promise.resolve(true); }),
      onAlarm: alarmsOnAlarm
    };
    // ── scripting, action, permissions, misc ──────────────────────────────────────────────────────
    chrome.scripting = {
      executeScript: api(null, d => call('scripting.executeScript', [{
        target: d.target, files: d.files || null, world: d.world || 'ISOLATED',
        func: d.func ? String(d.func) : (d.function ? String(d.function) : null), args: d.args || []
      }])),
      insertCSS: api(null, d => call('scripting.insertCSS', [{ target: d.target, files: d.files || null, css: d.css || null }])),
      removeCSS: api(null, d => call('scripting.removeCSS', [{ target: d.target, files: d.files || null, css: d.css || null }])),
      // scripts the extension registers at run time (blockers register most of their page scripts this way)
      registerContentScripts: api(null, scripts => call('scripting.registerContentScripts', [scripts || []])),
      unregisterContentScripts: api(null, filter => call('scripting.unregisterContentScripts', [filter || null])),
      getRegisteredContentScripts: api(null, filter => call('scripting.getRegisteredContentScripts', [filter || null])),
      updateContentScripts: api(null, scripts => call('scripting.updateContentScripts', [scripts || []])),
      ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN' }, StyleOrigin: { AUTHOR: 'AUTHOR', USER: 'USER' }
    };
    // ── userScripts (user-script managers, custom filters): only for extensions that ask for the permission ──
    if ((E.manifest.permissions || []).includes('userScripts')) {
      chrome.userScripts = {
        register: api(null, s => call('userScripts.register', [s || []])),
        update: api(null, s => call('userScripts.update', [s || []])),
        unregister: api(null, f => call('userScripts.unregister', [f || null])),
        getScripts: api(null, f => call('userScripts.getScripts', [f || null])),
        configureWorld: nop(undefined), resetWorldConfiguration: nop(undefined), getWorldConfigurations: nop([]),
        ExecutionWorld: { MAIN: 'MAIN', USER_SCRIPT: 'USER_SCRIPT' }
      };
    }
    const action = {
      setBadgeText: nop(undefined), getBadgeText: nop(''), setBadgeBackgroundColor: nop(undefined), setBadgeTextColor: nop(undefined),
      setIcon: nop(undefined), setTitle: nop(undefined), getTitle: nop(E.manifest.name || ''), setPopup: nop(undefined),
      getPopup: nop(getURL((E.manifest.action || E.manifest.browser_action || {}).default_popup || '')),
      enable: nop(undefined), disable: nop(undefined), isEnabled: nop(true),
      openPopup: api('action.openPopup'), getUserSettings: nop({ isOnToolbar: true }), onClicked: ev()
    };
    chrome.action = action; chrome.browserAction = action;
    // toolbar click on an extension without a popup: Chrome fires action.onClicked in the background
    G.__flintActionClicked = tab => { if (!action.onClicked.hasListeners()) return false; action.onClicked._fire(tab); return true; };
    // ── context menus: items in the page's right-click menu; clicks come back through onClicked / onclick ──
    const menuClicks = new Map(), menusOnClicked = ev();
    let menuSeq = 0;
    const menuProps = p => { const o = {}; for (const k in p || {}) if (k !== 'onclick' && typeof p[k] !== 'function') o[k] = p[k]; return o; };
    const menuCall = (op, args, cb) => { const p = call(op, args); p.then(() => cb && cb(), e => { lastError = { message: String(e && e.message || e) }; try { cb && cb(); } finally { lastError = undefined; } }); return p; };
    chrome.contextMenus = {
      create: (p, cb) => {
        p = p || {};
        const id = p.id !== undefined ? p.id : ++menuSeq;
        if (typeof p.onclick === 'function') menuClicks.set(id, p.onclick);
        menuCall('contextMenus.create', [{ ...menuProps(p), id }], cb).catch(() => {});
        return id;
      },
      update: (id, p, cb) => { if (p && typeof p.onclick === 'function') menuClicks.set(id, p.onclick); return menuCall('contextMenus.update', [id, menuProps(p)], cb); },
      remove: (id, cb) => { menuClicks.delete(id); return menuCall('contextMenus.remove', [id], cb); },
      removeAll: cb => { menuClicks.clear(); return menuCall('contextMenus.removeAll', [], cb); },
      onClicked: menusOnClicked, onShown: ev(), onHidden: ev(), refresh: () => {},
      ACTION_MENU_TOP_LEVEL_LIMIT: 6,
      ContextType: { ALL: 'all', PAGE: 'page', FRAME: 'frame', SELECTION: 'selection', LINK: 'link', EDITABLE: 'editable', IMAGE: 'image', VIDEO: 'video', AUDIO: 'audio', LAUNCHER: 'launcher', BROWSER_ACTION: 'browser_action', PAGE_ACTION: 'page_action', ACTION: 'action' },
      ItemType: { NORMAL: 'normal', CHECKBOX: 'checkbox', RADIO: 'radio', SEPARATOR: 'separator' }
    };
    chrome.menus = chrome.contextMenus;
    G.__flintMenuClicked = (info, tab) => { menusOnClicked._fire(info, tab); const f = menuClicks.get(info.menuItemId); if (f) { try { f(info, tab); } catch (e) { console.error(e); } } return true; };
    chrome.notifications = { create: nop('n'), clear: nop(true), getAll: nop({}), onClicked: ev(), onClosed: ev(), onButtonClicked: ev() };
    chrome.webNavigation = { onCommitted: ev(), onCompleted: ev(), onBeforeNavigate: ev(), onDOMContentLoaded: ev(), onHistoryStateUpdated: ev(), getFrame: nop(null), getAllFrames: nop([]) };
    chrome.webRequest = { onBeforeRequest: ev(), onBeforeSendHeaders: ev(), onHeadersReceived: ev(), onCompleted: ev(), onErrorOccurred: ev(), onAuthRequired: ev(), onBeforeRedirect: ev(), onResponseStarted: ev(), onSendHeaders: ev() };
    // ── declarativeNetRequest: rules run by WebKit's content blocker (see Flint's FDNR) ────────────────
    const dnr = op => api(null, (o) => call('dnr.' + op, [o === undefined ? null : o]));
    chrome.declarativeNetRequest = {
      updateDynamicRules: dnr('updateDynamicRules'), getDynamicRules: dnr('getDynamicRules'),
      updateSessionRules: dnr('updateSessionRules'), getSessionRules: dnr('getSessionRules'),
      updateEnabledRulesets: dnr('updateEnabledRulesets'), getEnabledRulesets: dnr('getEnabledRulesets'),
      updateStaticRules: dnr('updateStaticRules'), getDisabledRuleIds: dnr('getDisabledRuleIds'),
      getAvailableStaticRuleCount: dnr('getAvailableStaticRuleCount'), isRegexSupported: dnr('isRegexSupported'),
      getMatchedRules: dnr('getMatchedRules'), setExtensionActionOptions: dnr('setExtensionActionOptions'), testMatchOutcome: dnr('testMatchOutcome'),
      onRuleMatchedDebug: ev(),
      MAX_NUMBER_OF_DYNAMIC_RULES: 30000, MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000,
      MAX_NUMBER_OF_SESSION_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000, MAX_NUMBER_OF_REGEX_RULES: 1000,
      MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50, GUARANTEED_MINIMUM_STATIC_RULES: 30000,
      GETMATCHEDRULES_QUOTA_INTERVAL: 10, MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20,
      DYNAMIC_RULESET_ID: '_dynamic', SESSION_RULESET_ID: '_session',
      RuleActionType: { BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme', MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests' },
      ResourceType: { MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other' },
      DomainType: { FIRST_PARTY: 'firstParty', THIRD_PARTY: 'thirdParty' },
      RequestMethod: { CONNECT: 'connect', DELETE: 'delete', GET: 'get', HEAD: 'head', OPTIONS: 'options', PATCH: 'patch', POST: 'post', PUT: 'put', OTHER: 'other' },
      HeaderOperation: { APPEND: 'append', SET: 'set', REMOVE: 'remove' }
    };
    chrome.privacy = { services: { passwordSavingEnabled: { set: nop(undefined), get: nop({ value: false, levelOfControl: 'controllable_by_this_extension' }), clear: nop(undefined) }, autofillAddressEnabled: { set: nop(undefined), get: nop({ value: false }) }, autofillCreditCardEnabled: { set: nop(undefined), get: nop({ value: false }) } } };
    chrome.idle = { queryState: nop('active'), setDetectionInterval: () => {}, onStateChanged: ev() };
    chrome.commands = { getAll: nop([]), onCommand: ev() };
    chrome.offscreen = { createDocument: nop(undefined), closeDocument: nop(undefined), hasDocument: nop(false), Reason: { CLIPBOARD: 'CLIPBOARD', DOM_PARSER: 'DOM_PARSER' } };
    chrome.management = { getSelf: nop({ id: ID, name: E.manifest.name, version: E.manifest.version, enabled: true, installType: 'normal' }), onInstalled: ev(), onUninstalled: ev() };
    chrome.extension = { getURL, getViews: () => [], getBackgroundPage: () => null, inIncognitoContext: false, isAllowedIncognitoAccess: nop(false) };
    chrome.cookies = { get: nop(null), getAll: nop([]), set: nop(null), remove: nop(null), onChanged: ev() };
    chrome.sidePanel = { setOptions: nop(undefined), setPanelBehavior: nop(undefined), open: nop(undefined) };
  }
  chrome.permissions = { contains: nop(true), request: nop(true), remove: nop(true), getAll: nop({ permissions: E.manifest.permissions || [], origins: E.manifest.host_permissions || [] }), onAdded: ev(), onRemoved: ev() };

  G.chrome = chrome;
  G.browser = chrome;

  // Extension pages call their servers with the extension's host permissions: Flint makes the
  // request natively, so the page's origin and CORS don't get in the way.
  if (!IS_CONTENT) {
    const nativeFetch = G.fetch.bind(G);
    const b64 = buf => { let s = ''; const u = new Uint8Array(buf); for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); };
    G.fetch = async (input, init) => {
      const req = new Request(input, init);
      const u = new URL(req.url, location.href);
      if (!/^https?:$/.test(u.protocol)) return nativeFetch(input, init);
      const headers = {}; req.headers.forEach((v, k) => { headers[k] = v; });
      const body = ['GET', 'HEAD'].includes(req.method) ? null : b64(await req.arrayBuffer());
      const r = await call('net.fetch', [{ url: u.href, method: req.method, headers, body, credentials: req.credentials }]);
      if (!r || r.error) throw new TypeError('Failed to fetch' + (r && r.error ? ': ' + r.error : ''));
      const bin = atob(r.body || ''); const bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      const status = r.status >= 200 && r.status <= 599 ? r.status : 500;
      const res = new Response([101, 204, 205, 304].includes(status) ? null : bytes, { status: status === 304 ? 200 : status, statusText: r.statusText || '', headers: r.headers || {} });
      Object.defineProperty(res, 'url', { value: r.url || u.href });
      return res;
    };
  }

  if (IS_BG) {
    // service-worker style globals the background script may touch
    G.skipWaiting = () => Promise.resolve();
    G.clients = { claim: () => Promise.resolve(), matchAll: () => Promise.resolve([]), get: () => Promise.resolve(undefined), openWindow: u => call('tabs.create', [{ url: u, active: true }]) };
    G.registration = { scope: getURL(''), active: { state: 'activated' }, showNotification: () => Promise.resolve(), getNotifications: () => Promise.resolve([]) };
    G.importScripts = (...urls) => {
      // like a worker: relative paths resolve against the service worker script itself (js/service-worker.js →
      // "config.js" is js/config.js), not the background page Flint hosts it in
      const sw = E.manifest.background && E.manifest.background.service_worker;
      const base = (document.currentScript && document.currentScript.src) || (sw ? new URL('/' + sw.replace(/^\//, ''), location.href).href : location.href);
      for (const u of urls) {
        const x = new XMLHttpRequest(); x.open('GET', new URL(u, base).href, false); x.send();
        if (x.status && x.status >= 400) throw new Error('importScripts failed to load ' + u);
        // run it as a classic script, as a worker would: its top-level const/let/class become shared globals
        // (an eval keeps those to itself, which broke e.g. Enhancer for YouTube's `const config` → whole background dead)
        const s = document.createElement('script');
        s.textContent = x.responseText + '\n//# sourceURL=' + new URL(u, base).href;
        (document.head || document.documentElement).appendChild(s); s.remove();
      }
    };
    G.ServiceWorkerGlobalScope = G.ServiceWorkerGlobalScope || function ServiceWorkerGlobalScope() {};
  }

  if (IS_CONTENT) {
    // match patterns → which content scripts run in this frame
    G.__flintMatch = (patterns, url) => (patterns || []).some(p => {
      if (p === '<all_urls>') return /^(https?|file|ftp|wss?):/.test(url);
      const m = /^(\*|https?|file|ftp|wss?):\/\/([^/]*)(\/.*)$/.exec(p); if (!m) return false;
      const esc = s => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
      const scheme = m[1] === '*' ? '(https?|wss?)' : esc(m[1]);
      let host = m[2];
      host = host === '*' ? '[^/]*' : host.startsWith('*.') ? '([^/]*\\.)?' + esc(host.slice(2)) : esc(host);
      const path = esc(m[3]).replace(/\\\*/g, '.*').replace(/\*/g, '.*');
      return new RegExp('^' + scheme + '://' + host + '(:\\d+)?' + path + '$').test(url);
    });
  }
})();
