#!/usr/bin/env bash
# =============================================================================
# DADES DEL GUIÓ — La TdG · 25.10.2026
# Executa prepararDadesGuio() del projecte LaTdG (premsa local i defuncions,
# amb el mateix codi de l'Apps Script) i publica el resultat a la branca
# «dades-guio» d'aquest repo. generarGuioDiari() el llegeix de matinada i així
# no s'acosta al límit de 6 minuts de Google (vegeu DadesGuioGitHub.gs).
#
# Necessita: carpeta codi/LaTdG (repo privat latdg/apps-script) i GH_TOKEN.
# El bucle dels bots el crida de matinada; el workflow «Dades del guió» el
# llança a mà. A la sortida pública només hi surten recomptes.
# =============================================================================
set -u
REPO_BOTS="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

[ -d codi/LaTdG ] || { echo "⚠️ Dades del guió: falta el codi del projecte LaTdG."; exit 0; }

rm -rf /tmp/eg /tmp/dg && mkdir -p /tmp/eg /tmp/dg
node run.js --projecte LaTdG --codi codi/LaTdG --estat /tmp/eg \
  --funcio prepararDadesGuio --sortida /tmp/dg/dades-guio.json || true

# Registre detallat: només a la branca privada de l'estat (si hi és).
if [ -d estat ] && [ -f /tmp/eg/registre.txt ]; then
  mkdir -p estat/LaTdG && cp /tmp/eg/registre.txt estat/LaTdG/registre-guio.txt
fi

node -e '
  const fs = require("fs");
  let d; try { d = JSON.parse(fs.readFileSync("/tmp/dg/dades-guio.json", "utf8")); } catch (e) {}
  if (!d || !d.generat || typeof d.premsa !== "string" || !Array.isArray(d.defuncions)) {
    console.log("⚠️ Dades del guió: sense resultat vàlid; no es publica res.");
    process.exit(1);
  }
  const premsa = d.premsa.split(/\n\s*\n/).filter(b => /^\d+\./.test(b.trim())).length;
  console.log(`📝 Dades del guió: ${premsa} notícies de premsa (${d.segons.premsa} s), ${d.defuncions.length} defuncions (${d.segons.defuncions} s).`);
' || exit 0

(cd /tmp/dg && git init -q -b dades-guio && git add -A &&
 git -c user.name="La TdG (guió)" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
   commit -qm "Dades del guió ($(date '+%d.%m.%Y %H.%M'))" && git push -qf "$REPO_BOTS" dades-guio) \
 && echo "📝 Dades del guió publicades." || echo "⚠️ No s'han pogut publicar les dades del guió."
