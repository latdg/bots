// =============================================================================
// ADAPTADOR APPS SCRIPT → NODE — La TdG · 21.10.2026
//
// Imita els serveis de Google que fa servir el projecte Correu, perquè el
// MATEIX codi (sense tocar-ne cap línia) pugui córrer a GitHub Actions:
//   UrlFetchApp, Utilities, Logger, PropertiesService, CacheService,
//   LockService, Session, XmlService, SpreadsheetApp (només lectura, de la
//   còpia que en fa l'Apps Script), DriveApp i Drive/DocumentApp (OCR amb
//   Tesseract), ScriptApp, GmailApp/MailApp (desactivats), MimeType.
//
// La memòria (propietats, memòria cau, fitxers de Drive) és a l'objecte
// «magatzem», que run.js llegeix i desa a la branca privada estat-bots.
// En MODE PROVA no s'envia res: els missatges de Telegram i WhatsApp, les
// publicacions a GitHub i la resta d'escriptures es desen a «interceptats».
// =============================================================================
"use strict";

const { spawnSync, execSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { DOMParser } = require("@xmldom/xmldom");

const TZ_SCRIPT = "Europe/Madrid";

function crear(magatzem, opcions) {
  const prova = !!opcions.prova;
  const registre = opcions.registre || (t => process.stdout.write(t + "\n"));
  magatzem.props = magatzem.props || {};
  magatzem.cache = magatzem.cache || {};
  magatzem.drive = magatzem.drive || {};
  magatzem.fulls = magatzem.fulls || {};
  magatzem.interceptats = magatzem.interceptats || [];
  const estadistiques = { peticions: 0, interceptades: 0 };

  // ---------------------------------------------------------------------------
  // BYTES I BLOBS
  // ---------------------------------------------------------------------------
  const aBuffer = (dades, charset) => {
    if (dades == null) return Buffer.alloc(0);
    if (Buffer.isBuffer(dades)) return dades;
    if (dades instanceof Blob) return dades._b;
    if (Array.isArray(dades) || dades instanceof Uint8Array || dades instanceof Int8Array) {
      return Buffer.from(Array.from(dades, x => x & 255));
    }
    return codifica(String(dades), charset);
  };
  const aBytes = buf => Array.from(buf, x => (x > 127 ? x - 256 : x));   // com els byte[] de Java

  function codifica(text, charset) {
    const c = String(charset || "UTF-8").toLowerCase().replace(/_/g, "-");
    if (c === "utf-8" || c === "utf8") return Buffer.from(text, "utf8");
    if (c === "iso-8859-1" || c === "latin1" || c === "windows-1252" || c === "us-ascii") return Buffer.from(text, "latin1");
    return Buffer.from(text, "utf8");
  }

  function descodifica(buf, charset) {
    let c = String(charset || "UTF-8").trim().toLowerCase().replace(/_/g, "-");
    if (c === "utf8") c = "utf-8";
    try {
      return new TextDecoder(c).decode(buf);
    } catch (e) {
      return new TextDecoder("utf-8").decode(buf);
    }
  }

  class Blob {
    constructor(dades, tipus, nom) {
      this._b = aBuffer(dades);
      this._t = tipus || null;
      this._n = nom || null;
    }
    getBytes() { return aBytes(this._b); }
    getDataAsString(charset) { return descodifica(this._b, charset || "UTF-8"); }
    getContentType() { return this._t; }
    setContentType(t) { this._t = t; return this; }
    getName() { return this._n; }
    setName(n) { this._n = n; return this; }
    setDataFromString(s, charset) { this._b = codifica(String(s), charset); return this; }
    setBytes(b) { this._b = aBuffer(b); return this; }
    copyBlob() { return new Blob(Buffer.from(this._b), this._t, this._n); }
    getBlob() { return this; }
    isGoogleType() { return false; }
    getAs(tipus) {
      if (tipus === this._t) return this.copyBlob();
      throw new Error("getAs(" + tipus + ") no és disponible a GitHub");
    }
  }

  // ---------------------------------------------------------------------------
  // URLFETCHAPP
  // ---------------------------------------------------------------------------
  const RX_ENVIAMENTS = /api\.telegram\.org|whapi\.cloud|api\.bufferapp|api\.buffer\.com|bsky\.social|mastodon|hooks\.slack/i;

  function esEscriptura(url, metode) {
    if (RX_ENVIAMENTS.test(url)) return true;
    if (/api\.github\.com/i.test(url) && metode !== "GET") return true;
    return false;
  }

  function preparaPeticio(url, o) {
    o = o || {};
    const metode = String(o.method || "get").toUpperCase();
    const capcaleres = Object.assign({}, o.headers || {});
    let cos = null;
    let tipus = o.contentType || null;
    if (o.payload !== undefined && o.payload !== null) {
      const p = o.payload;
      if (p instanceof Blob) {
        cos = p._b;
        tipus = tipus || p._t || "application/octet-stream";
      } else if (typeof p === "object" && !Array.isArray(p) && !Buffer.isBuffer(p)) {
        const parells = Object.keys(p).map(k => {
          const v = p[k];
          return encodeURIComponent(k) + "=" + encodeURIComponent(v instanceof Blob ? v.getDataAsString() : String(v));
        });
        cos = Buffer.from(parells.join("&"), "utf8");
        tipus = tipus || "application/x-www-form-urlencoded";
      } else {
        cos = aBuffer(p);
        tipus = tipus || "application/x-www-form-urlencoded";
      }
    }
    if (tipus && !Object.keys(capcaleres).some(k => k.toLowerCase() === "content-type")) capcaleres["Content-Type"] = tipus;
    if (!Object.keys(capcaleres).some(k => k.toLowerCase() === "user-agent")) {
      capcaleres["User-Agent"] = "Mozilla/5.0 (compatible; Google-Apps-Script; beanserver; +https://script.google.com; id: UAEmdDd8)";
    }
    return {
      url: String(url), method: metode, headers: capcaleres,
      bodyB64: cos ? cos.toString("base64") : null,
      followRedirects: o.followRedirects !== false,
      validateCerts: o.validateHttpsCertificates !== false,
      mute: !!o.muteHttpExceptions
    };
  }

  class HTTPResponse {
    constructor(r) {
      this._r = r;
      this._b = Buffer.from(r.bodyB64 || "", "base64");
    }
    getResponseCode() { return this._r.status; }
    getHeaders() {
      const h = {};
      Object.keys(this._r.headers || {}).forEach(k => {
        const v = this._r.headers[k];
        h[k] = Array.isArray(v) ? v[v.length - 1] : v;
      });
      return h;
    }
    getAllHeaders() { return Object.assign({}, this._r.headers || {}); }
    getContent() { return aBytes(this._b); }
    getBlob() {
      const t = (this.getHeaders()["Content-Type"] || "application/octet-stream").split(";")[0].trim();
      return new Blob(Buffer.from(this._b), t, null);
    }
    getAs(t) { return this.getBlob().getAs(t); }
    getContentText(charset) {
      if (!charset) {
        const m = String(this.getHeaders()["Content-Type"] || "").match(/charset=["']?([\w-]+)/i);
        charset = m ? m[1] : "UTF-8";
      }
      return descodifica(this._b, charset);
    }
  }

  function executaPeticions(peticions) {
    const reals = [];
    const resultat = peticions.map(p => {
      if (prova && esEscriptura(p.url, p.method)) {
        estadistiques.interceptades++;
        const cos = p.bodyB64 ? Buffer.from(p.bodyB64, "base64").toString("utf8") : "";
        magatzem.interceptats.push({ quan: new Date().toISOString(), url: p.url.replace(/bot\d+:[\w-]+/, "bot***"), metode: p.method, cos: cos.slice(0, 6000) });
        const fals = /api\.github\.com/i.test(p.url) ? { content: { sha: "prova" }, commit: { sha: "prova" } } : { ok: true, result: {} };
        return { ok: true, status: p.method === "PUT" && /api\.github\.com/.test(p.url) ? 200 : 200, headers: { "Content-Type": "application/json" },
          bodyB64: Buffer.from(JSON.stringify(fals)).toString("base64") };
      }
      reals.push(p);
      return null;
    });
    if (reals.length) {
      estadistiques.peticions += reals.length;
      const fill = spawnSync(process.execPath, [path.join(__dirname, "fetch.mjs")], {
        input: JSON.stringify(reals), maxBuffer: 512 * 1024 * 1024, timeout: 180000, encoding: "utf8"
      });
      if (fill.status !== 0) throw new Error("UrlFetchApp: " + (fill.stderr || "error desconegut").slice(0, 300));
      const respostes = JSON.parse(fill.stdout);
      let k = 0;
      resultat.forEach((r, i) => { if (r === null) resultat[i] = respostes[k++]; });
    }
    return resultat;
  }

  function resposta(p, r) {
    if (!r.ok) throw new Error("Address unavailable: " + p.url + " (" + r.error + ")");
    const res = new HTTPResponse(r);
    if (!p.mute && r.status >= 400) {
      throw new Error("Request failed for " + p.url + " returned code " + r.status +
        ". Truncated server response: " + res.getContentText().slice(0, 200) + " (use muteHttpExceptions option to examine full response)");
    }
    return res;
  }

  const UrlFetchApp = {
    fetch(url, o) {
      const p = preparaPeticio(url, o);
      return resposta(p, executaPeticions([p])[0]);
    },
    fetchAll(llista) {
      const ps = llista.map(x => (typeof x === "string" ? preparaPeticio(x, {}) : preparaPeticio(x.url, x)));
      const rs = executaPeticions(ps);
      return ps.map((p, i) => resposta(p, rs[i]));
    },
    getRequest(url, o) { return preparaPeticio(url, o); }
  };

  // ---------------------------------------------------------------------------
  // DATES (patrons de Java SimpleDateFormat)
  // ---------------------------------------------------------------------------
  const MESOS_EN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  const DIES_EN = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

  function partsData(d, tz) {
    const f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz || TZ_SCRIPT, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric",
      hour: "numeric", minute: "numeric", second: "numeric", weekday: "short", timeZoneName: "longOffset"
    });
    const o = {};
    f.formatToParts(d).forEach(p => { o[p.type] = p.value; });
    const dow = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(o.weekday);
    const off = (o.timeZoneName || "GMT").replace("GMT", "") || "+00:00";
    return { y: +o.year, M: +o.month, d: +o.day, H: +o.hour % 24, m: +o.minute, s: +o.second, S: d.getMilliseconds(), dow, off };
  }

  function formatDate(data, tz, patro) {
    if (!(data instanceof Date) || isNaN(data.getTime())) throw new Error("Utilities.formatDate: data no vàlida");
    const p = partsData(data, tz);
    const pad = (n, l) => String(n).padStart(l, "0");
    let sortida = "";
    const s = String(patro);
    for (let i = 0; i < s.length;) {
      const c = s[i];
      if (c === "'") {
        const fi = s.indexOf("'", i + 1);
        if (fi === i + 1) { sortida += "'"; i += 2; continue; }
        sortida += s.slice(i + 1, fi === -1 ? s.length : fi);
        i = fi === -1 ? s.length : fi + 1;
        continue;
      }
      if (!/[a-zA-Z]/.test(c)) { sortida += c; i++; continue; }
      let n = 1;
      while (s[i + n] === c) n++;
      i += n;
      switch (c) {
        case "y": case "Y": sortida += n === 2 ? pad(p.y % 100, 2) : pad(p.y, n); break;
        case "M": case "L":
          sortida += n >= 4 ? MESOS_EN[p.M - 1] : n === 3 ? MESOS_EN[p.M - 1].slice(0, 3) : pad(p.M, n); break;
        case "d": sortida += pad(p.d, n); break;
        case "H": sortida += pad(p.H, n); break;
        case "k": sortida += pad(p.H === 0 ? 24 : p.H, n); break;
        case "h": sortida += pad(p.H % 12 === 0 ? 12 : p.H % 12, n); break;
        case "K": sortida += pad(p.H % 12, n); break;
        case "m": sortida += pad(p.m, n); break;
        case "s": sortida += pad(p.s, n); break;
        case "S": sortida += pad(p.S, 3).slice(0, Math.max(n, 3)); break;
        case "E": sortida += n >= 4 ? DIES_EN[p.dow] : DIES_EN[p.dow].slice(0, 3); break;
        case "u": sortida += String(p.dow === 0 ? 7 : p.dow); break;
        case "a": sortida += p.H < 12 ? "AM" : "PM"; break;
        case "D": {
          const inici = Date.UTC(p.y, 0, 1);
          sortida += pad(Math.floor((Date.UTC(p.y, p.M - 1, p.d) - inici) / 86400000) + 1, n);
          break;
        }
        case "Z": sortida += p.off.replace(":", ""); break;
        case "X": case "x": sortida += p.off === "+00:00" && c === "X" ? "Z" : (n >= 3 ? p.off : p.off.replace(":", "").slice(0, n === 1 ? 3 : 5)); break;
        case "z": sortida += "GMT" + p.off; break;
        default: sortida += c.repeat(n);
      }
    }
    return sortida;
  }

  // Moment UTC d'una data «de paret» en una zona horària.
  function dataZona(y, M, d, H, m, s, tz) {
    let t = Date.UTC(y, M - 1, d, H, m, s);
    for (let k = 0; k < 3; k++) {
      const p = partsData(new Date(t), tz);
      const vist = Date.UTC(p.y, p.M - 1, p.d, p.H, p.m, p.s);
      t += Date.UTC(y, M - 1, d, H, m, s) - vist;
    }
    return new Date(t);
  }

  function parseDate(text, tz, patro) {
    const v = { y: 1970, M: 1, d: 1, H: 0, m: 0, s: 0 };
    let i = 0;
    const s = String(text);
    const pt = String(patro);
    for (let k = 0; k < pt.length;) {
      const c = pt[k];
      if (!/[a-zA-Z]/.test(c)) {
        if (s[i] !== c) throw new Error("Unparseable date: \"" + text + "\"");
        i++; k++; continue;
      }
      let n = 1;
      while (pt[k + n] === c) n++;
      k += n;
      const m = s.slice(i).match(/^\d+/);
      if (!m) throw new Error("Unparseable date: \"" + text + "\"");
      i += m[0].length;
      const x = Number(m[0]);
      if (c === "y") v.y = n === 2 && m[0].length === 2 ? 2000 + x : x;
      else if (c === "M") v.M = x;
      else if (c === "d") v.d = x;
      else if (c === "H") v.H = x;
      else if (c === "m") v.m = x;
      else if (c === "s") v.s = x;
    }
    return dataZona(v.y, v.M, v.d, v.H, v.m, v.s, tz || TZ_SCRIPT);
  }

  // ---------------------------------------------------------------------------
  // UTILITIES
  // ---------------------------------------------------------------------------
  function parseCsv(text, sep) {
    sep = sep || ",";
    const files = [];
    let fila = [], camp = "", cometes = false;
    const s = String(text);
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (cometes) {
        if (c === '"') {
          if (s[i + 1] === '"') { camp += '"'; i++; } else cometes = false;
        } else camp += c;
      } else if (c === '"') cometes = true;
      else if (c === sep) { fila.push(camp); camp = ""; }
      else if (c === "\n" || c === "\r") {
        if (c === "\r" && s[i + 1] === "\n") i++;
        fila.push(camp); files.push(fila); fila = []; camp = "";
      } else camp += c;
    }
    if (camp !== "" || fila.length) { fila.push(camp); files.push(fila); }
    return files;
  }

  const Utilities = {
    Charset: { UTF_8: "UTF-8", US_ASCII: "US-ASCII" },
    DigestAlgorithm: { MD2: "md5", MD5: "md5", SHA_1: "sha1", SHA_256: "sha256", SHA_384: "sha384", SHA_512: "sha512" },
    MacAlgorithm: { HMAC_MD5: "md5", HMAC_SHA_1: "sha1", HMAC_SHA_256: "sha256", HMAC_SHA_384: "sha384", HMAC_SHA_512: "sha512" },
    formatDate,
    parseDate,
    parseCsv,
    sleep(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.max(0, Number(ms) || 0)); },
    computeDigest(alg, valor, charset) { return aBytes(crypto.createHash(alg).update(aBuffer(valor, charset)).digest()); },
    computeHmacSignature(alg, valor, clau, charset) {
      return aBytes(crypto.createHmac(alg, aBuffer(clau, charset)).update(aBuffer(valor, charset)).digest());
    },
    computeHmacSha256Signature(valor, clau, charset) { return this.computeHmacSignature("sha256", valor, clau, charset); },
    base64Encode(d, charset) { return aBuffer(d, charset).toString("base64"); },
    base64EncodeWebSafe(d, charset) { return aBuffer(d, charset).toString("base64").replace(/\+/g, "-").replace(/\//g, "_"); },
    base64Decode(s) { return aBytes(Buffer.from(String(s).replace(/\s/g, ""), "base64")); },
    base64DecodeWebSafe(s) { return aBytes(Buffer.from(String(s).replace(/-/g, "+").replace(/_/g, "/"), "base64")); },
    newBlob(d, tipus, nom) { return new Blob(d, tipus, nom); },
    getUuid() { return crypto.randomUUID(); },
    formatString(f, ...a) { let i = 0; return String(f).replace(/%[sdif]/g, () => String(a[i++])); },
    jsonStringify(o) { return JSON.stringify(o); },
    jsonParse(s) { return JSON.parse(s); },
    gzip(b) { return new Blob(require("zlib").gzipSync(b._b), "application/x-gzip"); },
    ungzip(b) { return new Blob(require("zlib").gunzipSync(b._b)); }
  };

  // ---------------------------------------------------------------------------
  // LOGGER I CONSOLE
  // ---------------------------------------------------------------------------
  const textLog = a => a.map(x => (typeof x === "string" ? x : x instanceof Error ? x.stack || x.message : (() => {
    try { return JSON.stringify(x); } catch (e) { return String(x); }
  })())).join(" ");
  const Logger = {
    log(f, ...a) {
      registre(typeof f === "string" && a.length && /%s/.test(f) ? Utilities.formatString(f, ...a) : textLog([f, ...a]));
      return Logger;
    },
    getLog() { return ""; },
    clear() {}
  };
  const consola = { log: (...a) => registre(textLog(a)), info: (...a) => registre(textLog(a)), warn: (...a) => registre(textLog(a)), error: (...a) => registre(textLog(a)) };

  // ---------------------------------------------------------------------------
  // PROPIETATS, MEMÒRIA CAU I BLOQUEIG
  // ---------------------------------------------------------------------------
  function propietats(obj) {
    return {
      getProperty: k => (Object.prototype.hasOwnProperty.call(obj, k) ? obj[k] : null),
      setProperty(k, v) { obj[k] = String(v); return this; },
      deleteProperty(k) { delete obj[k]; return this; },
      getProperties: () => Object.assign({}, obj),
      getKeys: () => Object.keys(obj),
      setProperties(o, esborrar) {
        if (esborrar) Object.keys(obj).forEach(k => delete obj[k]);
        Object.keys(o).forEach(k => { obj[k] = String(o[k]); });
        return this;
      },
      deleteAllProperties() { Object.keys(obj).forEach(k => delete obj[k]); return this; }
    };
  }
  magatzem.propsUsuari = magatzem.propsUsuari || {};
  const PropertiesService = {
    getScriptProperties: () => propietats(magatzem.props),
    getUserProperties: () => propietats(magatzem.propsUsuari),
    getDocumentProperties: () => null
  };

  function cau() {
    const c = magatzem.cache;
    const viu = k => {
      const e = c[k];
      if (!e) return null;
      if (e.fi < Date.now()) { delete c[k]; return null; }
      return e.v;
    };
    return {
      get: k => viu(k),
      put(k, v, seg) { c[k] = { v: String(v), fi: Date.now() + Math.min(21600, seg || 600) * 1000 }; },
      remove(k) { delete c[k]; },
      getAll(ks) { const o = {}; ks.forEach(k => { const v = viu(k); if (v !== null) o[k] = v; }); return o; },
      putAll(o, seg) { Object.keys(o).forEach(k => this.put(k, o[k], seg)); },
      removeAll(ks) { ks.forEach(k => delete c[k]); }
    };
  }
  const CacheService = { getScriptCache: cau, getUserCache: cau, getDocumentCache: () => null };

  const pany = () => ({ tryLock: () => true, waitLock: () => {}, releaseLock: () => {}, hasLock: () => true });
  const LockService = { getScriptLock: pany, getUserLock: pany, getDocumentLock: () => null };

  const Session = {
    getScriptTimeZone: () => TZ_SCRIPT,
    getActiveUser: () => ({ getEmail: () => "" }),
    getEffectiveUser: () => ({ getEmail: () => "" }),
    getTemporaryActiveUserKey: () => "github"
  };

  // ---------------------------------------------------------------------------
  // XMLSERVICE (sobre xmldom; mateixa semàntica d'espais de noms que JDOM)
  // ---------------------------------------------------------------------------
  const NS_CAP = { getURI: () => "", getPrefix: () => "" };
  const espai = (prefix, uri) => (uri === undefined ? { getURI: () => prefix || "", getPrefix: () => "" } : { getURI: () => uri || "", getPrefix: () => prefix || "" });

  function coincideix(node, nom, ns) {
    if (node.nodeType !== 1) return false;
    if (nom !== undefined && nom !== null && (node.localName || node.nodeName) !== nom) return false;
    const uri = ns ? ns.getURI() : "";
    return (node.namespaceURI || "") === uri;
  }

  function textDirecte(node) {
    let t = "";
    for (let c = node.firstChild; c; c = c.nextSibling) if (c.nodeType === 3 || c.nodeType === 4) t += c.data;
    return t;
  }

  function element(node) {
    if (!node) return null;
    return {
      _n: node,
      getName: () => node.localName || node.nodeName,
      getQualifiedName: () => node.nodeName,
      getNamespace(prefix) {
        if (prefix !== undefined) { const u = node.lookupNamespaceURI(prefix); return u ? espai(prefix, u) : null; }
        return node.namespaceURI ? espai(node.prefix || "", node.namespaceURI) : NS_CAP;
      },
      getChild(nom, ns) {
        for (let c = node.firstChild; c; c = c.nextSibling) if (coincideix(c, nom, ns)) return element(c);
        return null;
      },
      getChildren(nom, ns) {
        const r = [];
        for (let c = node.firstChild; c; c = c.nextSibling) {
          if (c.nodeType !== 1) continue;
          if (nom === undefined && ns === undefined) r.push(element(c));
          else if (coincideix(c, nom, ns)) r.push(element(c));
        }
        return r;
      },
      getChildText(nom, ns) { const e = this.getChild(nom, ns); return e ? e.getText() : null; },
      getChildTextTrim(nom, ns) { const e = this.getChild(nom, ns); return e ? e.getText().trim() : null; },
      getText: () => textDirecte(node),
      getTextTrim: () => textDirecte(node).trim(),
      getTextNormalize: () => textDirecte(node).replace(/\s+/g, " ").trim(),
      getValue: () => node.textContent || "",
      getAttribute(nom, ns) {
        const a = ns ? node.getAttributeNodeNS(ns.getURI(), nom) : node.getAttributeNode(nom);
        return a ? { getValue: () => a.value, getName: () => a.localName || a.name } : null;
      },
      getAttributes() {
        return Array.from(node.attributes || []).filter(a => !/^xmlns/.test(a.name))
          .map(a => ({ getValue: () => a.value, getName: () => a.localName || a.name }));
      },
      getParentElement: () => (node.parentNode && node.parentNode.nodeType === 1 ? element(node.parentNode) : null),
      getDescendants() {
        const r = [];
        const camina = n => { for (let c = n.firstChild; c; c = c.nextSibling) { if (c.nodeType === 1) { r.push(element(c)); camina(c); } } };
        camina(node);
        return r;
      },
      getContentSize: () => node.childNodes.length
    };
  }

  const XmlService = {
    parse(text) {
      const errors = [];
      const doc = new DOMParser({
        // Com el lector d'XML de Google (Xerces), qualsevol XML mal format és un error
        // (xmldom en diu «warning» d'algunes coses que Xerces no accepta).
        onError: (nivell, msg) => { errors.push(msg); },
        errorHandler: { warning: m => errors.push(m), error: m => errors.push(m), fatalError: m => errors.push(m) }
      }).parseFromString(String(text), "text/xml");
      if (errors.length || !doc || !doc.documentElement) {
        throw new Error("Error on line 1: " + (errors[0] || "Content is not allowed in prolog."));
      }
      return { getRootElement: () => element(doc.documentElement) };
    },
    getNamespace: (a, b) => espai(a, b),
    getNoNamespace: () => NS_CAP,
    getXmlNamespace: () => espai("xml", "http://www.w3.org/XML/1998/namespace")
  };

  // ---------------------------------------------------------------------------
  // SPREADSHEETAPP (només lectura, de la còpia exportada per l'Apps Script)
  // ---------------------------------------------------------------------------
  // Les dates es creen amb el Date global (el mateix «realm» que el codi d'Apps Script).
  const reviu = v => (v && typeof v === "object" && v.__data ? new Date(v.__data) : v);

  function full(id, nom) {
    const llibre = magatzem.fulls[id];
    const f = llibre && llibre.fulls ? llibre.fulls[nom] : null;
    if (!f) throw new Error("Full no disponible a GitHub (" + id + " / " + nom + "): cal que l'exporti l'Apps Script.");
    const valors = () => f.valors.map(r => r.map(reviu));
    const rang = (r0, c0, nf, nc) => ({
      getValues: () => valors().slice(r0 - 1, r0 - 1 + nf).map(r => r.slice(c0 - 1, c0 - 1 + nc)),
      getDisplayValues: () => (f.textos || f.valors).slice(r0 - 1, r0 - 1 + nf).map(r => r.slice(c0 - 1, c0 - 1 + nc).map(x => String(x ?? ""))),
      getNumRows: () => nf, getNumColumns: () => nc
    });
    return {
      getName: () => nom,
      getLastRow: () => f.valors.length,
      getLastColumn: () => f.valors.reduce((m, r) => Math.max(m, r.length), 0),
      getMaxRows: () => f.valors.length,
      getDataRange() { return rang(1, 1, this.getLastRow(), this.getLastColumn()); },
      getRange(a, b, c, d) {
        if (typeof a === "string") throw new Error("getRange amb notació A1 no disponible a GitHub");
        return rang(a, b, c || 1, d || 1);
      },
      appendRow() { throw new Error("Escriure a Google Sheets no és possible des de GitHub"); }
    };
  }

  function llibre(id) {
    const ll = magatzem.fulls[id];
    if (!ll) throw new Error("Full de càlcul no disponible a GitHub (" + id + "): cal que l'exporti l'Apps Script.");
    const noms = Object.keys(ll.fulls || {});
    return {
      getId: () => id,
      getName: () => ll.nom || id,
      getSheetByName: n => (noms.indexOf(n) !== -1 ? full(id, n) : null),
      getSheets: () => noms.map(n => full(id, n)),
      getActiveSheet: () => full(id, noms[0]),
      getSpreadsheetTimeZone: () => TZ_SCRIPT,
      getUrl: () => "https://docs.google.com/spreadsheets/d/" + id
    };
  }

  const SpreadsheetApp = {
    openById: llibre,
    openByUrl: u => llibre(String(u).match(/\/d\/([\w-]+)/)[1]),
    getActiveSpreadsheet: () => { throw new Error("No hi ha full actiu a GitHub"); },
    create: () => { throw new Error("Crear fulls de càlcul no és possible des de GitHub"); }
  };

  // ---------------------------------------------------------------------------
  // DRIVE (fitxers de text desats a la memòria) I OCR AMB TESSERACT
  // ---------------------------------------------------------------------------
  function fitxer(id) {
    const f = magatzem.drive[id];
    if (!f) throw new Error("No s'ha trobat el fitxer " + id + " (Drive no és disponible a GitHub)");
    return {
      getId: () => id,
      getName: () => f.nom,
      getBlob: () => new Blob(Buffer.from(f.b64 || "", "base64"), f.tipus || "text/plain", f.nom),
      setContent(t) { f.b64 = Buffer.from(String(t), "utf8").toString("base64"); return this; },
      setTrashed(x) { if (x) delete magatzem.drive[id]; return this; },
      getUrl: () => "",
      getSize: () => Buffer.from(f.b64 || "", "base64").length
    };
  }

  const DriveApp = {
    getFileById: fitxer,
    createFile(a, contingut, tipus) {
      const id = "github-" + crypto.randomBytes(8).toString("hex");
      const b = a instanceof Blob ? a._b : Buffer.from(String(contingut || ""), "utf8");
      magatzem.drive[id] = { nom: a instanceof Blob ? a.getName() : a, tipus: a instanceof Blob ? a._t : tipus, b64: b.toString("base64") };
      return fitxer(id);
    },
    getFilesByName: () => ({ hasNext: () => false, next: () => null })
  };

  const textosOcr = {};

  function ocr(buffer) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ocr-"));
    try {
      try { execSync("command -v tesseract && command -v pdftoppm", { stdio: "ignore" }); } catch (e) {
        execSync("sudo apt-get install -y -qq tesseract-ocr tesseract-ocr-cat poppler-utils", { stdio: "ignore", timeout: 240000 });
      }
      fs.writeFileSync(path.join(dir, "f.pdf"), buffer);
      // Primer, el text que porti el PDF; si no en porta (escanejat), OCR.
      let text = "";
      try { text = execSync(`pdftotext -layout "${dir}/f.pdf" -`, { encoding: "utf8", timeout: 60000 }); } catch (e) { text = ""; }
      if (text.replace(/\s/g, "").length > 50) return text;
      execSync(`pdftoppm -r 300 -png "${dir}/f.pdf" "${dir}/p"`, { timeout: 120000 });
      return fs.readdirSync(dir).filter(n => /^p.*\.png$/.test(n)).sort().map(n =>
        execSync(`tesseract "${dir}/${n}" - -l cat`, { encoding: "utf8", timeout: 120000, stdio: ["ignore", "pipe", "ignore"] })).join("\n");
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }

  const Drive = {
    Files: {
      create(meta, blob) {
        const id = "ocr-" + crypto.randomBytes(6).toString("hex");
        textosOcr[id] = ocr(blob._b);
        return { id, name: meta && meta.name };
      },
      insert(meta, blob) { return this.create(meta, blob); },
      remove(id) { delete textosOcr[id]; },
      delete(id) { delete textosOcr[id]; }
    }
  };

  const DocumentApp = {
    openById(id) {
      if (!(id in textosOcr)) throw new Error("Document no disponible a GitHub: " + id);
      return { getBody: () => ({ getText: () => textosOcr[id] }), getName: () => id };
    }
  };

  // ---------------------------------------------------------------------------
  // SERVEIS QUE NO S'USEN A GITHUB
  // ---------------------------------------------------------------------------
  const constructorActivador = new Proxy({}, { get: () => () => constructorActivador });
  const ScriptApp = {
    getProjectTriggers: () => [],
    deleteTrigger: () => {},
    newTrigger: () => constructorActivador,
    getScriptId: () => "github",
    getService: () => ({ getUrl: () => "" }),
    getOAuthToken: () => { throw new Error("Sense testimoni OAuth de Google a GitHub"); },
    WeekDay: { MONDAY: 1, TUESDAY: 2, WEDNESDAY: 3, THURSDAY: 4, FRIDAY: 5, SATURDAY: 6, SUNDAY: 7 },
    EventType: {}, AuthMode: {}
  };
  const correu = {
    sendEmail() { registre("✉️ [correu no enviat: a GitHub el correu està desactivat]"); },
    getRemainingDailyQuota: () => 0
  };
  const Charts = new Proxy({}, { get: () => { throw new Error("Charts no és disponible a GitHub"); } });
  const MimeType = {
    PLAIN_TEXT: "text/plain", PDF: "application/pdf", JSON: "application/json", HTML: "text/html", CSV: "text/csv",
    PNG: "image/png", JPEG: "image/jpeg", GOOGLE_DOCS: "application/vnd.google-apps.document",
    GOOGLE_SHEETS: "application/vnd.google-apps.spreadsheet", FOLDER: "application/vnd.google-apps.folder"
  };

  return {
    globals: {
      UrlFetchApp, Utilities, Logger, console: consola, PropertiesService, CacheService, LockService, Session,
      XmlService, SpreadsheetApp, DriveApp, Drive, DocumentApp, ScriptApp, GmailApp: correu, MailApp: correu,
      Charts, MimeType
    },
    estadistiques
  };
}

module.exports = { crear, TZ_SCRIPT };
