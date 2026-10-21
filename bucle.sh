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

passada() {
  git -C codi pull -q 2>/dev/null || true   # sempre la darrera versió del codi
  node run.js --codi codi/Correu --estat estat || true
  if [ -f estat/alertes/props.json ]; then
    node run.js --projecte alertes --codi codi/alertes --estat estat/alertes --fulls estat/fulls.json || true
  fi
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
