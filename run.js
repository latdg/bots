#!/usr/bin/env node
// =============================================================================
// EXECUTOR DEL PROJECTE CORREU A GITHUB — La TdG · 21.10.2026
//
// Carrega els fitxers del projecte Correu d'Apps Script TAL COM SÓN (del repo
// privat latdg/apps-script) amb l'adaptador gas/shim.js, i fa el paper dels
// activadors de Google: a cada execució (cada 30 minuts) decideix quines
// funcions toca córrer i les crida.
//
//   node run.js --codi <carpeta Correu> --estat <carpeta estat-bots> [--funcio nom]
//
// L'estat (propietats, memòria cau, fitxers) és a <estat>/estat.json. La còpia
// dels Google Sheets, a <estat>/fulls.json, i les propietats exportades per
// l'Apps Script en el traspàs, a <estat>/props.json (amb el mode: prova o real).
// Els registres detallats van a <estat>/registre.txt (privat): a la sortida
// pública només surten els noms de les funcions i el temps.
// =============================================================================
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { spawnSync } = require("child_process");
const { crear, TZ_SCRIPT } = require("./gas/shim");

const arg = nom => { const i = process.argv.indexOf("--" + nom); return i === -1 ? null : process.argv[i + 1]; };
const CODI = arg("codi");
const ESTAT = arg("estat");
const FULLS = arg("fulls") || (ESTAT && path.join(ESTAT, "fulls.json"));
const PROJECTE = arg("projecte") || "Correu";
const FUNCIO = arg("funcio");
const NOMES_CARREGA = process.argv.includes("--nomes-carrega");
const consola = console;

// Activadors que fa servir el projecte Correu i que corren a GitHub.
// tipus: "sempre" (cada execució), "hores" (a les hores de la constant),
// "cada" (cada N hores, constant), "dia" (un cop al dia, a l'hora de la constant).
// «minuts»: com a mínim tants minuts des de la darrera vegada (el workflow corre cada 15).
const ACTIVADORS_PER_PROJECTE = {};
ACTIVADORS_PER_PROJECTE.Correu = [
  { funcio: "comprovarPremsaInstant", tipus: "minuts", minuts: 25 },
  { funcio: "actualitzarResumPanell", tipus: "hores", constant: "PANELL_HORES" },
  { funcio: "actualitzarExtresPanell", tipus: "hores", constant: "PANELL_HORES_EXTRES" },
  { funcio: "comprovarDefuncionsMati", tipus: "dia", constant: "HORA_ENVIAMENT_DEFUNCIONS" },
  { funcio: "comprovarParlaments", tipus: "cada", constant: "PARLAMENTS_INTERVAL_HORES" },
  { funcio: "comprovarSubhastes", tipus: "cada", constant: "SUBHASTES_INTERVAL_HORES" },
  { funcio: "comprovarDadesMunicipals", tipus: "dia", constant: "DM_HORA_CONSULTA" }
];
// Bot d'esports (projecte LaTdG): la funció mateixa només consulta la FCF i la FEB
// quan hi ha algun partit dins la seva finestra (llegeix el calendari copiat).
ACTIVADORS_PER_PROJECTE.LaTdG = [
  { funcio: "comprovarResultatsEsportius", tipus: "sempre" }
];
const ACTIVADORS = ACTIVADORS_PER_PROJECTE[PROJECTE] || [];

function fitxersCodi() {
  return fs.readdirSync(CODI).filter(n => /\.(js|gs)$/.test(n)).sort((a, b) => a.localeCompare(b, "en"));
}

// Ordre de càrrega: com a l'Apps Script, tots els fitxers comparteixen l'àmbit
// global. Si un fitxer fa servir en carregar-se una constant d'un altre, s'ha
// de carregar després; es prova en un procés a part fins que l'ordre funciona.
function ordreCarrega() {
  let ordre = fitxersCodi();
  for (let intent = 0; intent < ordre.length * ordre.length; intent++) {
    const r = spawnSync(process.execPath, [__filename, "--codi", CODI, "--nomes-carrega", "--ordre", ordre.join("|")],
      { encoding: "utf8", env: process.env });
    if (r.status === 0) return ordre;
    const dolent = (r.stdout.match(/^FALLA:(.+)$/m) || [])[1];
    if (!dolent) throw new Error("No es pot carregar el codi: " + (r.stderr || r.stdout).slice(0, 500));
    ordre = ordre.filter(n => n !== dolent).concat(dolent);
  }
  throw new Error("No s'ha trobat cap ordre de càrrega vàlid");
}

function carrega(ordre) {
  ordre.forEach(nom => {
    const codi = fs.readFileSync(path.join(CODI, nom), "utf8");
    try {
      vm.runInThisContext(codi, { filename: nom });
    } catch (e) {
      if (NOMES_CARREGA) {
        consola.log("FALLA:" + nom);
        consola.error(e && e.stack);
        process.exit(1);
      }
      throw e;
    }
  });
}

const valor = nom => { try { return vm.runInThisContext(nom); } catch (e) { return undefined; } };

function horaMadrid(d) {
  const p = {};
  new Intl.DateTimeFormat("en-GB", { timeZone: TZ_SCRIPT, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit" })
    .formatToParts(d).forEach(x => { p[x.type] = x.value; });
  return { dia: `${p.year}-${p.month}-${p.day}`, hora: Number(p.hour) };
}

function toca(a, darrers, ara) {
  const { dia, hora } = horaMadrid(ara);
  const darrer = darrers[a.funcio] ? new Date(darrers[a.funcio]) : null;
  const d = darrer ? horaMadrid(darrer) : null;
  if (a.tipus === "sempre") return true;
  if (a.tipus === "minuts") return !darrer || ara - darrer >= a.minuts * 60000;
  const c = valor(a.constant);
  if (a.tipus === "hores") return Array.isArray(c) && c.indexOf(hora) !== -1 && !(d && d.dia === dia && d.hora === hora);
  if (a.tipus === "dia") return typeof c === "number" && hora >= c && !(d && d.dia === dia);
  if (a.tipus === "cada") return typeof c === "number" && (!darrer || ara - darrer >= (c * 60 - 10) * 60000);
  return false;
}

function llegeixJson(f, defecte) {
  try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { return defecte; }
}

function main() {
  if (NOMES_CARREGA) {
    const magatzem = {};
    const s = crear(magatzem, { prova: true, registre: () => {} });
    Object.assign(globalThis, s.globals);
    carrega(arg("ordre").split("|"));
    process.exit(0);
  }

  fs.mkdirSync(ESTAT, { recursive: true });
  const fitxerEstat = path.join(ESTAT, "estat.json");
  const magatzem = llegeixJson(fitxerEstat, {});
  magatzem.darrers = magatzem.darrers || {};

  // Traspàs: propietats exportades per l'Apps Script (passarBotsAGitHub / exportarPropietatsBots).
  const exportades = llegeixJson(path.join(ESTAT, "props.json"), null);
  if (exportades && exportades.generat && exportades.generat !== magatzem.importat) {
    magatzem.props = exportades.props || {};
    magatzem.importat = exportades.generat;
    magatzem.mode = exportades.mode === "real" ? "real" : "prova";
    magatzem.cache = {};
    consola.log(`Propietats importades de l'Apps Script (${Object.keys(magatzem.props).length}) · mode ${magatzem.mode}`);
  }
  magatzem.fulls = (llegeixJson(FULLS, {}) || {}).fulls || {};
  const prova = magatzem.mode !== "real" || process.env.FORCAR_PROVA === "1";
  if (prova) magatzem.interceptats = magatzem.interceptats || [];

  const linies = [];
  const registre = t => linies.push(`[${new Date().toISOString().slice(11, 19)}] ${t}`);
  const s = crear(magatzem, { prova, registre });
  Object.assign(globalThis, s.globals);

  const ordre = ordreCarrega();
  carrega(ordre);

  const ara = new Date();
  const fer = FUNCIO ? [{ funcio: FUNCIO }] : ACTIVADORS.filter(a => toca(a, magatzem.darrers, ara));
  consola.log(`${PROJECTE} · mode: ${prova ? "PROVA (no s'envia res)" : "real"} · ${ordre.length} fitxers · funcions: ${fer.map(a => a.funcio).join(", ") || "cap"}`);

  for (const a of fer) {
    const f = valor(a.funcio);
    if (typeof f !== "function") {
      consola.log(`  ${a.funcio}: no existeix al projecte`);
      continue;
    }
    registre(`========== ${a.funcio} ==========`);
    const t0 = Date.now();
    const p0 = s.estadistiques.peticions;
    let estat = "✅";
    try {
      f();
    } catch (e) {
      estat = "❌ " + String(e && e.message || e).slice(0, 80).replace(/https?:\/\/\S+/g, "(url)");
      registre("❌ " + (e && e.stack || e));
    }
    magatzem.darrers[a.funcio] = ara.toISOString();
    consola.log(`  ${a.funcio}: ${estat} · ${Math.round((Date.now() - t0) / 1000)} s · ${s.estadistiques.peticions - p0} peticions`);
  }

  // Neteja i desa.
  Object.keys(magatzem.cache || {}).forEach(k => { if (magatzem.cache[k].fi < Date.now()) delete magatzem.cache[k]; });
  if (magatzem.interceptats) magatzem.interceptats = magatzem.interceptats.slice(-800);
  delete magatzem.fulls;
  fs.writeFileSync(fitxerEstat, JSON.stringify(magatzem));

  const fitxerRegistre = path.join(ESTAT, "registre.txt");
  const anterior = fs.existsSync(fitxerRegistre) ? fs.readFileSync(fitxerRegistre, "utf8").split("\n") : [];
  const capcalera = `##### ${new Date().toLocaleString("ca-ES", { timeZone: TZ_SCRIPT })} · ${prova ? "PROVA" : "real"} #####`;
  fs.writeFileSync(fitxerRegistre, anterior.concat([capcalera], linies).slice(-6000).join("\n"));
  consola.log(`Peticions: ${s.estadistiques.peticions} · interceptades (prova): ${s.estadistiques.interceptades}`);
}

main();
