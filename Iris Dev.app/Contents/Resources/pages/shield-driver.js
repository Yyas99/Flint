// Iris (MIT): builds uBlock Origin's own scriptlet injection code from uBO's source files (GPL-3, downloaded at run time,
// never bundled) and the lists' +js filters.
// Runs in JavaScriptCore inside Iris. Inputs (globals): __files {path: source}, __filters [[domains, argsText, isException]],
// __templates {begin, core, end}, __secret. Output: JSON string from __irisBuild().
(function () {
  const G = globalThis;
  if (!G.console) G.console = { log() {}, warn() {}, error() {}, info() {} };
  if (!G.self) G.self = G;
  if (!G.structuredClone) G.structuredClone = function clone(v) {
    if (v instanceof Map) return new Map(Array.from(v, ([k, x]) => [clone(k), clone(x)]));
    if (v instanceof Set) return new Set(Array.from(v, clone));
    if (Array.isArray(v)) return v.map(clone);
    if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v)) o[k] = clone(v[k]); return o; }
    return v;
  };
  if (!Array.prototype.toSorted) Array.prototype.toSorted = function (f) { return this.slice().sort(f); };

  // a tiny module system: each uBO file becomes a function returning its exports
  const norm = (from, rel) => {
    const parts = from.split('/'); parts.pop();
    for (const p of rel.split('/')) { if (p === '.' || p === '') continue; if (p === '..') parts.pop(); else parts.push(p); }
    return parts.join('/');
  };
  const cache = {};
  const transform = (path, src) => {
    const exportsList = [];
    let s = src.replace(/^\s*import\s+['"]([^'"]+)['"];?/gm, (m, rel) => `__req(${JSON.stringify(norm(path, rel))});`);
    s = s.replace(/^\s*import\s+([^'";]*?)\s+from\s+['"]([^'"]+)['"];?/gm, (m, what, rel) => {
      const target = JSON.stringify(norm(path, rel));
      what = what.trim();
      if (what.startsWith('{')) return `const ${what.replace(/\s+as\s+/g, ': ')} = __req(${target});`;
      if (what.startsWith('*')) return `const ${what.replace(/^\*\s+as\s+/, '')} = __req(${target});`;
      return `const ${what} = __req(${target}).default;`;
    });
    s = s.replace(/^export\s+(async\s+function|function\*?|class|const|let|var)\s+([A-Za-z_$][\w$]*)/gm, (m, kind, name) => { exportsList.push([name, name]); return `${kind} ${name}`; });
    s = s.replace(/^export\s+default\s+/gm, () => { exportsList.push(['default', '__default__']); return 'const __default__ = '; });
    s = s.replace(/^export\s*\{([^}]*)\};?/gm, (m, list) => {
      for (const item of list.split(',')) { const t = item.trim(); if (!t) continue; const mm = t.split(/\s+as\s+/); exportsList.push([mm[1] || mm[0], mm[0]]); }
      return '';
    });
    const ret = exportsList.map(([k, v]) => `${JSON.stringify(k)}: ${v}`).join(', ');
    return `(function(){\n${s}\n;return {${ret}};\n})`;
  };
  G.__req = path => {
    if (cache[path]) return cache[path];
    const src = G.__files[path];
    if (src === undefined) { cache[path] = {}; return cache[path]; }
    cache[path] = {};
    const fn = (0, eval)(transform(path, src));
    const out = fn();
    Object.assign(cache[path], out);
    return cache[path];
  };

  // uBO's own argument parser, as uBO's filter parser uses it for +js(...)
  const parseArgs = (text, ArglistParser) => {
    const p = new ArglistParser(',');
    const out = [];
    let beg = 0;
    const len = text.length;
    while (beg < len) {
      p.nextArg(text, beg);
      let a = text.slice(p.argBeg, p.argEnd);
      if (p.transform) a = p.normalizeArg(a);
      out.push(a);
      if (p.separatorEnd <= beg) break;
      beg = p.separatorEnd;
      if (beg === len && p.separatorBeg !== p.separatorEnd) out.push('');
    }
    return out;
  };

  G.__irisBuild = function () {
    const scriptlets = __req('resources/scriptlets.js').builtinScriptlets;
    const make = __req('make-scriptlets.js');
    const { ArglistParser } = __req('arglist-parser.js');
    make.resetAll();
    make.init(scriptlets);
    // group the filters as uBO does: one entry per distinct argument list, with the sites it applies to and skips
    const byArgs = new Map(), broadOff = new Set();
    let rejected = 0;
    for (const [domains, argsText, isException] of G.__filters) {
      const args = argsText.trim() === '' ? [] : parseArgs(argsText, ArglistParser);
      const hns = [], nots = [];
      for (let d of String(domains || '').split(',')) { d = d.trim(); if (!d) continue; if (d.startsWith('~')) nots.push(d.slice(1)); else hns.push(d); }
      if (args.length === 0) { if (isException) for (const h of hns) broadOff.add(h); continue; }
      let token = args[0]; if (!token.endsWith('.js')) token += '.js';
      const key = JSON.stringify([token, ...args.slice(1)]);
      let e = byArgs.get(key); if (!e) { e = { args: [token, ...args.slice(1)], matches: new Set(), excludeMatches: new Set() }; byArgs.set(key, e); }
      if (isException) { for (const h of hns) e.excludeMatches.add(h); continue; }
      if (hns.length === 0) { rejected++; continue; }   // uBO: only exceptions may be global
      for (const h of hns) e.matches.add(h);
      for (const h of nots) e.excludeMatches.add(h);
    }
    if (broadOff.size) make.compile('Iris', { args: [], excludeMatches: Array.from(broadOff) });
    let compiled = 0;
    for (const e of byArgs.values()) {
      if (e.matches.size === 0) continue;
      const details = { args: e.args.slice(), matches: Array.from(e.matches), trustedSource: true };
      if (e.excludeMatches.size) details.excludeMatches = Array.from(e.excludeMatches);
      try { make.compile('Iris', details); compiled++; } catch (x) { rejected++; }
    }
    const core = make.commit('Iris', G.__templates.core, G.__secret);
    const fw = make.commitFramework(G.__templates.begin, G.__templates.end, G.__secret);
    const out = { compiled, rejected, worlds: {} };
    for (const world of ['MAIN', 'ISOLATED']) {
      if (!core[world]) continue;
      out.worlds[world] = { code: [fw[world].beginCode, core[world].code, fw[world].endCode].join('\n'), hostnames: core[world].hostnames };
    }
    return JSON.stringify(out);
  };
  // uBlock's stand-in scripts: canonical name → its aliases (only the JavaScript ones can be planted in a page)
  G.__irisRedirects = function () {
    const map = __req('redirect-resources.js').default;
    const out = {};
    if (!(map instanceof Map)) return '{}';
    for (const [name, details] of map) {
      if (!/\.js$/.test(name)) continue;
      const al = details && details.alias;
      out[name] = Array.isArray(al) ? al : al ? [al] : [];
    }
    return JSON.stringify(out);
  };
})();
