// Fa les peticions HTTP de UrlFetchApp (s'executa en un procés a part perquè
// UrlFetchApp és síncron). Llegeix un JSON per l'entrada estàndard:
//   [{url, method, headers, bodyB64, followRedirects, validateCerts}]
// i escriu: [{ok, error, status, headers, bodyB64, url}]
import { Agent, setGlobalDispatcher } from "undici";

const entrada = JSON.parse(await new Promise(r => {
  let s = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", d => (s += d));
  process.stdin.on("end", () => r(s));
}));

// Com Google: espera prou a connectar i no obre massa connexions alhora al mateix servidor
// (amb 9 consultes simultànies, les dades obertes de la Generalitat tallaven la connexió).
setGlobalDispatcher(new Agent({ connect: { timeout: 60000 }, connections: 4 }));
const insegur = new Agent({ connect: { rejectUnauthorized: false, timeout: 60000 }, connections: 4 });
const TEMPS_MS = 180000;   // algunes consultes de dades obertes triguen més d'un minut

async function una(p) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TEMPS_MS);
  try {
    let url = p.url;
    let method = (p.method || "GET").toUpperCase();
    let body = p.bodyB64 != null ? Buffer.from(p.bodyB64, "base64") : undefined;
    let r;
    // Les redireccions es fan a mà per poder deixar-les de seguir (followRedirects: false).
    for (let salts = 0; salts < 10; salts++) {
      r = await fetch(url, {
        method, headers: p.headers || {}, body: ["GET", "HEAD"].includes(method) ? undefined : body,
        redirect: "manual", signal: ctrl.signal, dispatcher: p.validateCerts === false ? insegur : undefined
      });
      const loc = r.headers.get("location");
      if (p.followRedirects === false || ![301, 302, 303, 307, 308].includes(r.status) || !loc) break;
      url = new URL(loc, url).toString();
      if (r.status === 303 || ((r.status === 301 || r.status === 302) && method === "POST")) {
        method = "GET";
        body = undefined;
      }
    }
    const buf = Buffer.from(await r.arrayBuffer());
    const headers = {};
    r.headers.forEach((v, k) => {
      // Noms com els dona Apps Script (Content-Type, Set-Cookie...).
      const nom = k.replace(/(^|-)([a-z])/g, (m, a, b) => a + b.toUpperCase());
      headers[nom] = headers[nom] !== undefined ? [].concat(headers[nom], v) : v;
    });
    return { ok: true, status: r.status, headers, bodyB64: buf.toString("base64"), url };
  } catch (e) {
    return { ok: false, error: String(e && e.cause ? e.cause.code || e.cause.message || e.message : e) };
  } finally {
    clearTimeout(t);
  }
}

// Un segon intent si la connexió falla (no si el servidor respon amb un error).
async function ambReintent(p) {
  const r = await una(p);
  if (r.ok || !/CONNECT_TIMEOUT|ECONNRESET|ETIMEDOUT|EAI_AGAIN|SOCKET|aborted/i.test(r.error)) return r;
  await new Promise(res => setTimeout(res, 3000));
  return una(p);
}

const sortida = await Promise.all(entrada.map(ambReintent));
process.stdout.write(JSON.stringify(sortida));
