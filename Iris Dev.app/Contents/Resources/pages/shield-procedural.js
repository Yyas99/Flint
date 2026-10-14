// Iris (MIT): element hiding that plain CSS can't express — uBlock Origin's procedural operators (:has-text, :upward,
// :remove, :style, :matches-css, :xpath and the rest), and selectors for "example.*" sites. Runs in Iris's own world,
// re-applies as the page changes. The table (site → selectors) is passed in by Iris.
(function (T) {
  'use strict';
  if (!T || !location.hostname || self.__irisProcedural) return;
  self.__irisProcedural = true;
  const host = location.hostname.toLowerCase();
  const keys = new Set();
  const parts = host.split('.');
  for (let i = 0; i < parts.length; i++) {
    const p = parts.slice(i);
    keys.add(p.join('.'));
    if (p.length >= 2) keys.add(p.slice(0, -1).join('.') + '.*');
    if (p.length >= 3) keys.add(p.slice(0, -2).join('.') + '.*');
  }
  const on = new Set(), off = new Set();
  for (const k of keys) { const list = T[k]; if (!list) continue; for (const [sel, exc] of list) (exc ? off : on).add(sel); }
  if (T['*']) for (const [sel, exc] of T['*']) if (exc) off.add(sel);
  const selectors = [...on].filter(s => !off.has(s));
  if (!selectors.length) return;

  const token = 'i' + Math.random().toString(36).slice(2, 10);
  const OPS = 'has-text|contains|-abp-contains|has|-abp-has|if|if-not|not|upward|nth-ancestor|matches-css|matches-css-before|matches-css-after|min-text-length|matches-attr|matches-path|matches-media|xpath|watch-attr|spath|others|shadow|matches-prop|remove|style|remove-attr|remove-class';
  const reOp = new RegExp(':(' + OPS + ')\\(', 'g');
  const isProcedural = s => { reOp.lastIndex = 0; return reOp.test(s); };

  // the text inside balanced parentheses starting at i (just after "("); quotes and /regex/ respected
  const balanced = (s, i) => {
    let depth = 1, q = 0;
    for (let j = i; j < s.length; j++) {
      const c = s[j];
      if (q) { if (c === '\\') { j++; continue; } if (c === q) q = 0; continue; }
      if (c === '"' || c === "'") { q = c; continue; }
      if (c === '\\') { j++; continue; }
      if (c === '(') depth++;
      else if (c === ')') { depth--; if (depth === 0) return [s.slice(i, j), j + 1]; }
    }
    return null;
  };
  const toRegex = (a, flagsDefault = '') => {
    a = String(a).trim();
    const m = /^\/(.+)\/([a-z]*)$/s.exec(a);
    if (m) { try { return new RegExp(m[1], m[2] || flagsDefault); } catch (e) { return /(?!)/; } }
    if (/^(["']).*\1$/.test(a)) a = a.slice(1, -1);
    return new RegExp(a.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), flagsDefault);
  };
  const parse = (sel, relative) => {
    sel = sel.trim();
    const out = { css: '', tasks: [], action: null, relative: !!relative };
    reOp.lastIndex = 0;
    let m = reOp.exec(sel);
    // :has()/:not() that hold only plain CSS stay plain CSS
    if (!m) { out.css = sel; return out; }
    out.css = sel.slice(0, m.index).trim();
    let i = m.index;
    while (i < sel.length) {
      if (sel[i] === ':') {
        reOp.lastIndex = i;
        const mm = reOp.exec(sel);
        if (!mm || mm.index !== i) {   // a native pseudo-class after a procedural one: treat the rest as a path
          const rest = sel.slice(i); out.tasks.push(['spath', rest]); break;
        }
        const b = balanced(sel, i + mm[0].length);
        if (!b) return null;
        const op = mm[1], arg = b[0];
        if (op === 'remove') out.action = ['remove'];
        else if (op === 'style') out.action = ['style', arg];
        else if (op === 'remove-attr' || op === 'remove-class') out.action = [op, arg];
        else if (op === 'has' || op === '-abp-has' || op === 'if' || op === 'not' || op === 'if-not') {
          const sub = parse(arg, true); if (!sub) return null;
          out.tasks.push([op === 'not' || op === 'if-not' ? 'not' : 'has', sub]);
        } else out.tasks.push([op, arg]);
        i = b[1];
      } else {   // plain CSS after an operator: " > .x", ".x" — a path from the current elements
        let j = i, depth = 0, q = 0;
        for (; j < sel.length; j++) {
          const c = sel[j];
          if (q) { if (c === q) q = 0; continue; }
          if (c === '"' || c === "'") { q = c; continue; }
          if (c === '(' || c === '[') depth++; else if (c === ')' || c === ']') depth--;
          else if (c === ':' && depth === 0) { reOp.lastIndex = j; const x = reOp.exec(sel); if (x && x.index === j) break; }
        }
        const path = sel.slice(i, j);
        if (path.trim()) out.tasks.push(['spath', path]);
        i = j;
      }
    }
    return out;
  };
  const scopeCss = css => /^\s*[>+~]/.test(css) ? ':scope ' + css : css;
  const ancestors = (n, k) => { while (n && k-- > 0) n = n.parentElement; return n; };
  const watchAttrs = new Set();
  const exec = (p, roots) => {
    let nodes = [];
    if (p.css) {
      for (const r of roots) {
        try { nodes.push(...(r.querySelectorAll ? r.querySelectorAll(p.relative ? scopeCss(p.css) : p.css) : [])); } catch (e) { return []; }
      }
    } else nodes = p.relative ? roots.slice() : [document.documentElement];
    for (const [op, arg] of p.tasks) {
      if (!nodes.length) break;
      switch (op) {
        case 'has-text': case 'contains': case '-abp-contains': { const re = toRegex(arg); nodes = nodes.filter(n => re.test(n.textContent)); break; }
        case 'has': nodes = nodes.filter(n => exec(arg, [n]).length > 0); break;
        case 'not': nodes = nodes.filter(n => exec(arg, [n]).length === 0); break;
        case 'upward': {
          const a = String(arg).trim();
          nodes = nodes.map(n => /^\d+$/.test(a) ? ancestors(n, +a) : (n.parentElement && n.parentElement.closest(a))).filter(Boolean); break;
        }
        case 'nth-ancestor': nodes = nodes.map(n => ancestors(n, +arg)).filter(Boolean); break;
        case 'matches-css': case 'matches-css-before': case 'matches-css-after': {
          const k = arg.indexOf(':'); if (k < 0) { nodes = []; break; }
          const prop = arg.slice(0, k).trim(), re = toRegex(arg.slice(k + 1).trim());
          const pseudo = op === 'matches-css-before' ? '::before' : op === 'matches-css-after' ? '::after' : null;
          nodes = nodes.filter(n => re.test(getComputedStyle(n, pseudo).getPropertyValue(prop))); break;
        }
        case 'min-text-length': nodes = nodes.filter(n => (n.textContent || '').length >= +arg); break;
        case 'matches-attr': {
          const mm = /^\s*("?)(.+?)\1\s*(?:=\s*(.+))?$/.exec(arg); if (!mm) { nodes = []; break; }
          const reName = toRegex(mm[2]), reVal = mm[3] !== undefined ? toRegex(mm[3]) : null;
          nodes = nodes.filter(n => Array.from(n.attributes).some(at => reName.test(at.name) && (!reVal || reVal.test(at.value)))); break;
        }
        case 'matches-path': { const re = toRegex(arg); if (!re.test(location.pathname + location.search)) nodes = []; break; }
        case 'matches-media': if (!matchMedia(arg).matches) nodes = []; break;
        case 'xpath': {
          const out = [];
          for (const n of nodes) {
            try {
              const r = document.evaluate(arg, n, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
              for (let i = 0; i < r.snapshotLength; i++) { const x = r.snapshotItem(i); if (x.nodeType === 1) out.push(x); }
            } catch (e) {}
          }
          nodes = out; break;
        }
        case 'watch-attr': for (const a of String(arg).split(',')) if (a.trim()) watchAttrs.add(a.trim().replace(/^["']|["']$/g, '')); break;
        case 'spath': {
          const out = [];
          for (const n of nodes) { try { out.push(...n.querySelectorAll(scopeCss(arg.trim()))); } catch (e) {} }
          nodes = out; break;
        }
        default: nodes = []; break;   // others(), shadow(), matches-prop(): not supported
      }
    }
    return nodes;
  };

  const plain = [], procedural = [];
  for (const s of selectors) {
    if (!isProcedural(s)) { plain.push(s); continue; }
    const p = parse(s, false);
    if (p) procedural.push(p);
  }
  const sheet = document.createElement('style');
  let css = `[${token}]{display:none!important}`;
  for (const s of plain) css += `\n${s}{display:none!important}`;
  const styleIds = new Map();
  procedural.forEach((p, i) => { if (p.action && p.action[0] === 'style') { styleIds.set(p, i); css += `\n[${token}s~="${i}"]{${p.action[1]}}`; } });
  sheet.textContent = css;
  const attach = () => { const r = document.head || document.documentElement; if (r && sheet.parentNode !== r) r.appendChild(sheet); };
  attach();
  // a stylesheet some plain selectors can't parse would drop them all: test them one by one, keep the good ones
  try { sheet.sheet && sheet.sheet.cssRules; } catch (e) {}

  const apply = () => {
    attach();
    for (const p of procedural) {
      let nodes;
      try { nodes = exec(p, [document]); } catch (e) { continue; }
      for (const n of nodes) {
        const a = p.action;
        if (!a) { n.setAttribute(token, ''); continue; }
        if (a[0] === 'remove') { n.remove(); continue; }
        if (a[0] === 'style') { const id = String(styleIds.get(p)); const cur = (n.getAttribute(token + 's') || '').split(' '); if (!cur.includes(id)) n.setAttribute(token + 's', (cur.join(' ') + ' ' + id).trim()); continue; }
        if (a[0] === 'remove-attr') { for (const x of String(a[1]).split('|')) n.removeAttribute(x.trim()); continue; }
        if (a[0] === 'remove-class') { for (const x of String(a[1]).split('|')) n.classList.remove(x.trim()); continue; }
      }
    }
  };
  let pending = false, last = 0;
  const schedule = () => {
    if (pending) return; pending = true;
    const wait = Math.max(0, 120 - (Date.now() - last));
    setTimeout(() => requestAnimationFrame(() => { pending = false; last = Date.now(); apply(); }), wait);
  };
  const start = () => {
    apply();
    new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true, attributes: watchAttrs.size > 0, attributeFilter: watchAttrs.size ? [...watchAttrs] : undefined, characterData: false });
  };
  if (procedural.length) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true }); else start();
  }
})
