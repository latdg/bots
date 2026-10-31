#!/usr/bin/env bash
# =============================================================================
# BUCLE DELS BOTS — La TdG · 21.10.2026
# L'horari de GitHub («schedule») arriba amb hores de retard en aquest compte,
# o no arriba. Per això el workflow no espera l'horari: es queda en marxa unes
# 5 h 30 min i, cada 5 minuts, executa els projectes (run.js decideix quines
# funcions toquen per l'hora, com feien els activadors de Google). Al final es
# torna a llançar ell mateix. L'horari del workflow queda com a reserva per si
# la cadena s'atura.
#   bucle.sh             -> bucle
#   bucle.sh una "funció" -> només una funció del projecte Correu, una vegada
# =============================================================================
set -u
DURADA=${DURADA:-19800}      # 5 h 30 min
PAS=${PAS:-300}              # cada 5 minuts
URL="https://x-access-token:${TOKEN}@github.com/latdg/apps-script.git"
FI=$((SECONDS + DURADA))

desa() {
  [ -f estat/estat.json ] || return 0
  rm -rf /tmp/nou /tmp/r && mkdir -p /tmp/nou /tmp/r
  # props.json i fulls.json (de qualsevol projecte) els escriu l'Apps Script: es prenen els de GitHub.
  if git -C estat fetch -q --depth 1 "$URL" estat-bots 2>/dev/null; then
    for f in $(git -C estat ls-tree -r --name-only FETCH_HEAD | grep -E '(^|/)(props|fulls)\.json$'); do
      mkdir -p "estat/$(dirname "$f")"
      git -C estat show "FETCH_HEAD:$f" > "/tmp/r/x" 2>/dev/null && mv /tmp/r/x "estat/$f"
    done
  fi
  (cd estat && find . -path ./.git -prune -o -type f -print | cpio -pdm --quiet /tmp/nou)
  (cd /tmp/nou && git init -q -b estat-bots && git add -A &&
   git -c user.name="La TdG (bots)" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
     commit -qm "Estat dels bots ($(date '+%d.%m.%Y %H.%M'))" && git push -qf "$URL" estat-bots) \
   || echo "⚠️ No s'ha pogut desar l'estat (es tornarà a provar)."
}

# LLAMPS A DEMANDA (21.10.2026): el botó privat de la pàgina dels llamps (via el
# Worker latdg-llamps) deixa una petició a la branca «peticions» d'aquest repo
# (llamps.json: {"id", "hores"}). Aquí s'atén a la passada següent (com a molt
# 5 minuts) i el resultat es publica a la branca «llamps-dades».
REPO_BOTS="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
llamps() {
  [ -f estat/alertes/props.json ] || return 0
  rm -rf /tmp/pet && git clone -q --depth 1 --branch peticions "$REPO_BOTS" /tmp/pet 2>/dev/null || return 0
  [ -f /tmp/pet/llamps.json ] || return 0
  id=$(node -e 'console.log(require("/tmp/pet/llamps.json").id||"")')
  hores=$(node -e 'console.log(Number(require("/tmp/pet/llamps.json").hores)||6)')
  [ -n "$id" ] || return 0
  grep -qx "$id" estat/alertes/llamps-fets.txt 2>/dev/null && return 0
  echo "⚡ Petició de llamps $id: $hores h"
  rm -f /tmp/llamps.json
  node run.js --projecte alertes --codi codi/alertes --estat estat/alertes --fulls estat/fulls.json \
    --funcio revisarLlampsWeb --args "[$hores]" --sortida /tmp/llamps.json || true
  echo "$id" >> estat/alertes/llamps-fets.txt
  [ -s /tmp/llamps.json ] || return 0
  rm -rf /tmp/ll && (git clone -q --depth 1 --branch llamps-dades "$REPO_BOTS" /tmp/ll 2>/dev/null || mkdir -p /tmp/ll)
  rm -rf /tmp/ll/.git && mkdir -p /tmp/ll/historic
  node -e '
    const fs=require("fs"); const r=JSON.parse(fs.readFileSync("/tmp/llamps.json","utf8")); r.id=process.argv[1];
    fs.writeFileSync("/tmp/ll/darrer.json", JSON.stringify(r));
    fs.writeFileSync("/tmp/ll/historic/"+r.id+".json", JSON.stringify(r));
    let idx=[]; try{idx=JSON.parse(fs.readFileSync("/tmp/ll/index.json","utf8"))}catch(e){}
    idx.unshift({id:r.id, generat:r.generat, hores:r.hores, a10:r.llamps.filter(l=>l.km<=10).length, a50:r.llamps.length});
    fs.writeFileSync("/tmp/ll/index.json", JSON.stringify(idx.slice(0,200)));' "$id"
  (cd /tmp/ll && git init -q -b llamps-dades && git add -A &&
   git -c user.name="La TdG (llamps)" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
     commit -qm "Llamps ($id)" && git push -qf "$REPO_BOTS" llamps-dades) || echo "⚠️ No s'han pogut publicar els llamps."
}

# LOTERIES I PARLAMENT (21.10.2026): els scripts de PowerShell que corrien al
# portàtil (ps/). Una vegada al dia, a partir de les 7 h, en segon pla (triguen
# uns minuts i no han d'aturar els bots). Fan servir Chrome en comptes d'Edge.
# El testimoni del bot d'infos i el del panell surten de les propietats del
# projecte Correu i es desen fora de la carpeta d'estat (no es pugen enlloc).
# La memòria (vistos, termes, registre) va a estat/ps (branca privada).
PS_PID=""
ps_diari() {
  [ "$(date +%-H)" -ge 7 ] || return 0
  [ "$(cat estat/ps/fet.txt 2>/dev/null)" = "$(date +%F)" ] && return 0
  [ -n "$PS_PID" ] && kill -0 "$PS_PID" 2>/dev/null && return 0
  [ -f estat/props.json ] || return 0
  mkdir -p estat/ps /tmp/ps-cfg && chmod 700 /tmp/ps-cfg
  for f in ps/inicial/*.json; do [ -f "estat/ps/$(basename "$f")" ] || cp "$f" estat/ps/; done
  prova=$(node -e '
    const fs=require("fs"); const e=JSON.parse(fs.readFileSync("estat/props.json","utf8")); const p=e.props||{};
    fs.writeFileSync("/tmp/ps-cfg/config.json", JSON.stringify({token:p.TELEGRAM_BOT_TOKEN_INFOS||"", chat_id:p.TELEGRAM_CHAT_ID_INFOS||""}), {mode:0o600});
    fs.writeFileSync("/tmp/ps-cfg/panell.txt", p.GITHUB_TOKEN_PANELL||"", {mode:0o600});
    console.log(e.mode==="real" ? "" : "-Prova");')
  echo "🍀🏛️ Loteries i Parlament ${prova}"
  (
    export NAVEGADOR="$PWD/ps/navegador.sh" LATDG_CARPETA="$PWD/estat/ps" \
           LATDG_CONFIG=/tmp/ps-cfg/config.json LATDG_TOKEN_PANELL=/tmp/ps-cfg/panell.txt
    pwsh -NoProfile -File ps/LoteriesLaTdG.ps1 $prova > estat/ps/sortida-loteries.txt 2>&1
    echo "Loteries: $(tail -n 1 estat/ps/sortida-loteries.txt)"
    pwsh -NoProfile -File ps/ParlamentLaTdG.ps1 $prova > estat/ps/sortida-parlament.txt 2>&1
    echo "Parlament: $(tail -n 1 estat/ps/sortida-parlament.txt)"
    date +%F > estat/ps/fet.txt
  ) &
  PS_PID=$!
}

# BLOCS DE WEBS DEL TAULER (21.10.2026): aire, Pla Alfa, sequera, refugis, BORME
# i subhastes (abans a publicarTaulerTdG de l'Apps Script). Un cop cada hora, de
# 8 a 23 h; cada bloc es consulta segons la seva freqüència (TaulerWebsGitHub.gs).
# El resultat va a la branca «tauler-webs» d'aquest repo, i el tauler en directe
# (latdg/tauler) l'afegeix al tauler.
tauler_webs() {
  local h; h=$(date +%-H)
  [ "$h" -ge 8 ] || return 0
  [ "$(cat estat/tauler-webs.txt 2>/dev/null)" = "$(date +%F-%H)" ] && return 0
  [ -d codi/LaTdG ] || return 0
  rm -f /tmp/webs.json
  node run.js --projecte LaTdG --codi codi/LaTdG --estat estat/LaTdG \
    --funcio taulerWebsGitHub --sortida /tmp/webs.json > /dev/null 2>&1 || true
  date +%F-%H > estat/tauler-webs.txt
  [ -s /tmp/webs.json ] || { echo "⚠️ Blocs de webs del tauler: sense resultat."; return 0; }
  node -e 'const d=JSON.parse(require("fs").readFileSync("/tmp/webs.json","utf8")); process.exit(d.consultats && d.consultats.length ? 0 : 1)' || return 0
  rm -rf /tmp/tw && mkdir -p /tmp/tw && cp /tmp/webs.json /tmp/tw/webs.json
  (cd /tmp/tw && git init -q -b tauler-webs && git add -A &&
   git -c user.name="La TdG (tauler)" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
     commit -qm "Blocs de webs del tauler ($(date '+%d.%m.%Y %H.%M'))" && git push -qf "$REPO_BOTS" tauler-webs) \
   && echo "🌐 Blocs de webs del tauler publicats." || echo "⚠️ No s'han pogut publicar els blocs de webs del tauler."
}

# AVISOS DE METEOCAT PER AL TAULER (31.10.2026): l'avisador d'incidències desa a
# la propietat SMP_TAULER tots els avisos de l'SMP de la comarca cada vegada que
# consulta Meteocat (com a molt cada 8 h). Si han canviat, es publiquen a la
# branca «tauler-alertes» d'aquest repo i el tauler en directe (latdg/tauler) els
# mostra al bloc d'avisos meteorològics. Cap consulta més a Meteocat.
tauler_alertes() {
  [ -f estat/alertes/estat.json ] || return 0
  node -e '
    const fs=require("fs"); const e=JSON.parse(fs.readFileSync("estat/alertes/estat.json","utf8"));
    const s=(e.props||{}).SMP_TAULER; if (!s) process.exit(1);
    fs.writeFileSync("/tmp/smp.json", s);' 2>/dev/null || return 0
  cmp -s /tmp/smp.json estat/tauler-alertes.json && return 0
  rm -rf /tmp/ta && mkdir -p /tmp/ta && cp /tmp/smp.json /tmp/ta/smp.json
  (cd /tmp/ta && git init -q -b tauler-alertes && git add -A &&
   git -c user.name="La TdG (tauler)" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
     commit -qm "Avisos de Meteocat per al tauler ($(date '+%d.%m.%Y %H.%M'))" && git push -qf "$REPO_BOTS" tauler-alertes) \
   && cp /tmp/smp.json estat/tauler-alertes.json && echo "🌦️ Avisos de Meteocat del tauler publicats." \
   || echo "⚠️ No s'han pogut publicar els avisos de Meteocat del tauler."
}

# DADES DEL GUIÓ (25.10.2026): premsa i defuncions per al guió del dia, a les
# 4, les 5 i les 6 h (una vegada a cada hora; el guió surt cap a les 6.37 h). Vegeu guio.sh.
GUIO_HORES=" 4 5 6 "
dades_guio() {
  local h; h=$(date +%-H)
  case "$GUIO_HORES" in *" $h "*) ;; *) return 0 ;; esac
  [ "$(cat estat/dades-guio.txt 2>/dev/null)" = "$(date +%F-%H)" ] && return 0
  date +%F-%H > estat/dades-guio.txt
  ./guio.sh || true
}

# AVÍS DE LA CASA (25.10.2026): cada dos dies a les 16 h, a partir del dilluns
# 26.10.2026, un recordatori al bot privat d'infos (LaTdG_infos). Una sola vegada
# per dia; en MODE PROVA no s'envia.
CASA_INICI="2026-10-26"
casa() {
  [ "$(date +%-H)" -eq 16 ] || return 0
  local dies
  dies=$(( ( $(date -u -d "$(date +%F)" +%s) - $(date -u -d "$CASA_INICI" +%s) ) / 86400 ))
  [ "$dies" -ge 0 ] && [ $((dies % 2)) -eq 0 ] || return 0
  [ "$(cat estat/casa.txt 2>/dev/null)" = "$(date +%F)" ] && return 0
  [ -f estat/props.json ] || return 0
  local cfg
  cfg=$(node -e '
    const e=JSON.parse(require("fs").readFileSync("estat/props.json","utf8")); const p=e.props||{};
    if (e.mode==="real" && p.TELEGRAM_BOT_TOKEN_INFOS && p.TELEGRAM_CHAT_ID_INFOS)
      console.log(p.TELEGRAM_BOT_TOKEN_INFOS+" "+p.TELEGRAM_CHAT_ID_INFOS);')
  date +%F > estat/casa.txt
  [ -n "$cfg" ] || { echo "🧹 Avís de la casa: mode prova, no s'envia."; return 0; }
  set -- $cfg
  curl -s -o /dev/null "https://api.telegram.org/bot$1/sendMessage" \
    --data-urlencode "chat_id=$2" \
    --data-urlencode "text=🧹 Toca feina a casa: sacsejar el sofà, netejar la taula i passar l'aspiradora.
Si no és cap d'aquestes, se'n poden fer d'altres: la roba del pis de dalt, o netejar i aspirar la cuina." \
    && echo "🧹 Avís de la casa enviat." || echo "⚠️ No s'ha pogut enviar l'avís de la casa."
}

passada() {
  git -C codi pull -q 2>/dev/null || true   # sempre la darrera versió del codi
  node run.js --codi codi/Correu --estat estat || true
  if [ -f estat/alertes/props.json ]; then
    node run.js --projecte alertes --codi codi/alertes --estat estat/alertes --fulls estat/fulls.json || true
  fi
  llamps
  ps_diari
  tauler_webs
  tauler_alertes
  dades_guio
  casa
  rm -f estat/diagnosi.txt
  desa
}

if [ "${1:-}" = "una" ]; then
  node run.js --codi codi/Correu --estat estat --funcio "$2" || true
  desa
  exit 0
fi

while :; do
  echo "----- $(date '+%H.%M') -----"
  passada
  ara=$(date +%s)
  espera=$(( PAS - (ara % PAS) + 20 ))      # alineat als múltiples de 5 minuts (+20 s)
  [ $((SECONDS + espera + 120)) -ge $FI ] && break
  sleep "$espera"
done

# Si Loteries o el Parlament encara corren, s'esperen abans de plegar.
if [ -n "$PS_PID" ]; then wait "$PS_PID"; desa; fi
