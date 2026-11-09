# =============================================================================
# BOT LATDG_INFOS: FUTBOL DES DE CASA — La TdG · 09.11.2026
#
# La FCF bloqueja els servidors (Google, GitHub i, des del 09.11.2026,
# Cloudflare). Mentre no hi hagi la Raspberry Pi de casa, el futbol va així:
#
#  · FITXER DE LA FCF. El marcador «Futbol → La TdG» (www.fcf.cat) baixa
#    futbol-tdg.json. Si s'envia a aquest bot, ensenya un resum i, amb el botó
#    «Desa», el desa a dades/esports-fcf.json (latdg/tauler). El mateix es pot
#    fer a la pàgina latdg.github.io/tauler/esports/.
#  · DIVENDRES A LES 17 H. Llista dels partits de futbol de divendres a diumenge
#    amb tres botons: ✅ Correcte, ✏️ Canvia l'hora i ⏸ Ajornat.
#  · DIA DE PARTIT. Dues hores després de l'inici, pregunta el resultat (i una
#    hora més tard, si no s'ha contestat). Es respon al missatge amb el
#    marcador, el local primer («2-1»). Amb «✅ Publica»:
#      - es desa a dades/esports-manual.json (tauler, guió), i
#      - es posa a dades/esports-fcf.json com a acta tancada: el bot d'esports
#        (Apps Script) el publica al canal de La Torre de Guaita com sempre.
#  · CADA 10 MINUTS. Els canvis fets aquí (hores i resultats) es tornen a posar
#    a dades/esports-fcf.json si un fitxer nou de la FCF els ha esborrat i la
#    FCF encara no té l'acta tancada.
#
# Només atén el xat de l'Ignasi (TELEGRAM_CHAT_ID_INFOS). L'estat es desa a la
# branca privada «bot-infos» de latdg/apps-script. El repo és públic: al
# registre no hi surt cap clau ni cap dada.
#
#   python bot_infos.py --props <estat-bots/props.json> --props-esports <estat-bots/esports/props.json>
#   python bot_infos.py --prova     (proves sense xarxa)
# =============================================================================
import base64
import datetime as dt
import json
import os
import re
import secrets
import sys
import time
from zoneinfo import ZoneInfo

import requests

TZ = ZoneInfo("Europe/Madrid")
TAULER = "latdg/tauler"
ESTAT_REPO = "latdg/apps-script"
ESTAT_BRANCA = "bot-infos"
ESTAT_CAMI = "estat.json"
F_ESPORTS = "dades/esports.json"
F_MANUAL = "dades/esports-manual.json"
F_FCF = "dades/esports-fcf.json"
PAGINA = "https://latdg.github.io/tauler/esports/#gestio"
DURADA = int(os.environ.get("DURADA", str(5 * 3600 + 40 * 60)))

EQUIPS = {
    "atletic_bisbalenc": {"nom": "Atlètic Bisbalenc", "grup": "58161863", "codi": "33220"},
    "monells_a": {"nom": "Monells A", "grup": "58161891", "codi": "36200"},
    "la_pera": {"nom": "La Pera", "grup": "58161891", "codi": "36734"},
    "monells_b": {"nom": "Monells B", "grup": "58161893", "codi": "54312692"},
    "la_pera_femeni": {"nom": "La Pera femení", "grup": "58162320", "codi": "15549744"},
}
DIES = ["dl", "dt", "dc", "dj", "dv", "ds", "dg"]
DIVENDRES_HORA = 17
LLISTA_HORA_LIMIT = 19              # divendres: la llista surt igualment a aquesta hora
LLISTA_ESPERA_MIN = 4               # minuts després de desar el fitxer (que el tauler s'actualitzi)
DILLUNS_HORA = 18                   # 09.11.2026: recordatori setmanal del fitxer de la FCF
RESULTAT_DESPRES_MIN = 120          # primera pregunta, 2 h després de l'inici
RESULTAT_SEGONA_MIN = 180           # segona i última, 3 h després
FINESTRA_PUBLICACIO_MIN = 8 * 60    # el bot d'esports publica fins a 8 h després de l'inici


def ara():
    return dt.datetime.now(TZ)


def amaga(text):
    """Treu qualsevol clau de bot de Telegram d'un text (el registre és públic)."""
    return re.sub(r"bot\d+:[A-Za-z0-9_-]+", "bot***", str(text))


def log(*a):
    print(ara().strftime("%H.%M"), *(amaga(x) for x in a), flush=True)


# -----------------------------------------------------------------------------
# Format
# -----------------------------------------------------------------------------
def data_ca(iso):
    try:
        d = dt.date.fromisoformat(iso)
    except (TypeError, ValueError):
        return iso or "—"
    return f"{DIES[d.weekday()]} {d.strftime('%d.%m.%Y')}"


def hora_ca(h):
    return (h or "").replace(":", ".") + " h" if h else "hora per fixar"


def nom_partit(eq_nom, p):
    """«Nostre – RIVAL», el local primer."""
    nostre = eq_nom.upper()
    return f"{nostre} – {p.get('rival', '')}" if p.get("localVisitant") == "Local" else f"{p.get('rival', '')} – {nostre}"


def linia_partit(eq_nom, p):
    t = f"{eq_nom} · {data_ca(p.get('data'))}, {hora_ca(p.get('hora'))}\n{nom_partit(eq_nom, p)}"
    if p.get("jornada"):
        t += f" (jornada {p['jornada']})"
    if p.get("camp"):
        t += f"\n{p['camp']}"
    if re.search(r"ajorn", p.get("estat") or "", re.I):
        t += "\n⏸ Ajornat"
    return t


def llegeix_hora(text, data_base):
    """«18.30», «14.11 18.30», «ds 14.11.2026 18:30» → (data_iso, «HH:MM») o None."""
    t = re.sub(r"\b(dl|dt|dc|dj|dv|ds|dg)\b\.?", " ", text.lower()).strip()
    t = re.sub(r"\s*h\s*$", "", t)
    m = re.fullmatch(r"(?:(\d{1,2})[./-](\d{1,2})(?:[./-](\d{2,4}))?\s+)?(\d{1,2})[.:h](\d{2})", t.strip())
    if not m:
        return None
    dia, mes, any_, hh, mm = m.groups()
    if int(hh) > 23 or int(mm) > 59:
        return None
    if dia:
        base = dt.date.fromisoformat(data_base) if data_base else ara().date()
        a = int(any_) if any_ else base.year
        if a < 100:
            a += 2000
        try:
            data = dt.date(a, int(mes), int(dia))
        except ValueError:
            return None
        if not any_ and data < ara().date() - dt.timedelta(days=180):
            data = data.replace(year=data.year + 1)
        data_iso = data.isoformat()
    else:
        data_iso = data_base
    return data_iso, f"{int(hh):02d}:{mm}"


def llegeix_marcador(text):
    m = re.fullmatch(r"\s*(\d{1,2})\s*[-–:]\s*(\d{1,2})\s*", text or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


# -----------------------------------------------------------------------------
# GitHub
# -----------------------------------------------------------------------------
class GitHub:
    def __init__(self, token):
        self.s = requests.Session()
        self.s.headers.update({"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                               "User-Agent": "latdg-bot-infos"})

    def llegeix(self, repo, cami, branca="main"):
        r = self.s.get(f"https://api.github.com/repos/{repo}/contents/{cami}", params={"ref": branca}, timeout=40)
        if r.status_code == 404:
            return None, None
        r.raise_for_status()
        d = r.json()
        if d.get("content"):
            text = base64.b64decode(d["content"]).decode("utf-8")
        else:   # més d'1 MB
            text = self.s.get(d["download_url"], timeout=60).text
        return json.loads(text), d["sha"]

    def desa(self, repo, cami, dades, sha, missatge, branca="main"):
        text = json.dumps(dades, ensure_ascii=False, indent=1) + "\n"
        cos = {"message": missatge, "content": base64.b64encode(text.encode("utf-8")).decode("ascii"), "branch": branca,
               "committer": {"name": "La TdG (bot infos)", "email": "41898282+github-actions[bot]@users.noreply.github.com"}}
        if sha:
            cos["sha"] = sha
        r = self.s.put(f"https://api.github.com/repos/{repo}/contents/{cami}", json=cos, timeout=60)
        if r.status_code in (409, 422):
            raise Conflicte()
        r.raise_for_status()
        return r.json()["content"]["sha"]

    def assegura_branca(self, repo, branca):
        r = self.s.get(f"https://api.github.com/repos/{repo}/git/ref/heads/{branca}", timeout=30)
        if r.status_code == 200:
            return
        main = self.s.get(f"https://api.github.com/repos/{repo}/git/ref/heads/main", timeout=30)
        main.raise_for_status()
        self.s.post(f"https://api.github.com/repos/{repo}/git/refs", timeout=30,
                    json={"ref": "refs/heads/" + branca, "sha": main.json()["object"]["sha"]}).raise_for_status()


class Conflicte(Exception):
    pass


def modifica(gh, repo, cami, canvi, missatge, perdefecte=None, intents=4):
    """Llegeix, aplica canvi(dades) (torna False si no hi ha res a fer) i desa; si algú
    ha escrit entremig, ho torna a provar amb la versió nova."""
    for _ in range(intents):
        dades, sha = gh.llegeix(repo, cami)
        if dades is None:
            if perdefecte is None:
                return None
            dades = json.loads(json.dumps(perdefecte))
        if canvi(dades) is False:
            return False
        try:
            gh.desa(repo, cami, dades, sha, missatge)
            return True
        except Conflicte:
            time.sleep(2)
    raise RuntimeError("no s'ha pogut desar " + cami + " (conflicte)")


# -----------------------------------------------------------------------------
# Telegram
# -----------------------------------------------------------------------------
class Telegram:
    def __init__(self, token, chat):
        self.base = "https://api.telegram.org/bot" + token
        self.fitxers = "https://api.telegram.org/file/bot" + token
        self.chat = str(chat)

    def crida(self, metode, timeout=40, **dades):
        r = requests.post(f"{self.base}/{metode}", json=dades, timeout=timeout)
        d = r.json()
        if not d.get("ok"):
            raise RuntimeError(f"Telegram {metode}: {d.get('error_code')} {d.get('description', '')[:120]}")
        return d["result"]

    def envia(self, text, botons=None, resposta_forcada=False, respon_a=None):
        dades = {"chat_id": self.chat, "text": text, "disable_web_page_preview": True}
        if botons:
            dades["reply_markup"] = {"inline_keyboard": botons}
        elif resposta_forcada:
            dades["reply_markup"] = {"force_reply": True, "input_field_placeholder": "Escriu aquí"}
        if respon_a:
            dades["reply_to_message_id"] = respon_a
        return self.crida("sendMessage", **dades)

    def edita(self, missatge_id, text):
        try:
            self.crida("editMessageText", chat_id=self.chat, message_id=missatge_id, text=text,
                       disable_web_page_preview=True)
        except RuntimeError as e:
            if "not modified" not in str(e):
                log("⚠️", e)

    def respon_boto(self, id_, text=""):
        try:
            self.crida("answerCallbackQuery", callback_query_id=id_, text=text)
        except RuntimeError:
            pass

    def _updates(self, offset):
        r = requests.post(f"{self.base}/getUpdates", timeout=65,
                          json={"offset": offset, "timeout": 50, "allowed_updates": ["message", "callback_query"]})
        d = r.json()
        if not d.get("ok"):
            raise RuntimeError(f"Telegram getUpdates: {d.get('error_code')} {d.get('description', '')[:120]}")
        return d["result"]

    def baixa(self, file_id):
        f = self.crida("getFile", file_id=file_id)
        r = requests.get(f"{self.fitxers}/{f['file_path']}", timeout=60)
        r.raise_for_status()
        return r.content


# -----------------------------------------------------------------------------
# Dades de futbol
# -----------------------------------------------------------------------------
def partits_futbol(esports):
    """[(equip_id, partit)] dels nostres equips de futbol que venen de la FCF."""
    llista = []
    for e in (esports or {}).get("equips", []):
        if e.get("id") not in EQUIPS:
            continue
        for p in e.get("partits", []):
            if str(p.get("clau", "")).startswith("FCF-"):
                llista.append((e["id"], p))
    llista.sort(key=lambda x: (x[1].get("data") or "9999", x[1].get("hora") or "99"))
    return llista


def ordinal(n):
    return {1: "1r", 2: "2n", 3: "3r", 4: "4t"}.get(n, f"{n}è")


def resum_fcf(f, avui):
    linies = []
    for eid, eq in EQUIPS.items():
        g = (f.get("grups") or {}).get(eq["grup"])
        if not g:
            linies.append(f"{eq['nom']}: el fitxer no porta el seu grup.")
            continue
        fila = next((x for x in (g.get("classificacio") or {}).get("data") or []
                     if str((x.get("team") or {}).get("teamId")) == eq["codi"]), None)
        proper = None
        for llista in ((g.get("partidos") or {}).get("partidos") or {}).values():
            for m in llista or []:
                if eq["codi"] not in (str(m.get("CODEQUIPO_CASA")), str(m.get("CODEQUIPO_FUERA"))):
                    continue
                d = str(m.get("COMIENZO1") or "")
                if str(m.get("CERRADA")) == "1" or d[:10] < avui:
                    continue
                if not proper or d < str(proper.get("COMIENZO1")):
                    proper = m
        try:
            t = f"{eq['nom']}: {ordinal(int(float(fila['position'])))}, {int(float(fila['points']))} punts ({int(float(fila['played']))} partits)" if fila else f"{eq['nom']}: sense classificació"
        except (TypeError, ValueError, KeyError):
            t = f"{eq['nom']}: classificació il·legible"
        if proper:
            d = str(proper.get("COMIENZO1"))
            local = str(proper.get("CODEQUIPO_CASA")) == eq["codi"]
            hora = d[11:16] if len(d) >= 16 and d[11:16] != "00:00" else ""
            t += f" · proper: {data_ca(d[:10])}{', ' + hora_ca(hora) if hora else ''} " \
                 f"{'contra' if local else 'a'} {proper.get('NOMBRE_FUERA') if local else proper.get('NOMBRE_CASA')}"
        linies.append(t)
    return linies


def fitxer_valid(f):
    if not isinstance(f, dict) or f.get("tipus") != "latdg-fcf" or not isinstance(f.get("grups"), dict):
        return False
    for g, v in f["grups"].items():
        if g not in {e["grup"] for e in EQUIPS.values()}:
            return False
        jornades = ((v or {}).get("partidos") or {}).get("partidos")
        if not isinstance(jornades, dict) or not jornades:
            return False
        if not isinstance(((v or {}).get("classificacio") or {}).get("data"), list):
            return False
    return bool(f["grups"])


def aplica_correccions(fcf, manual):
    """Posa al fitxer de la FCF les hores i els resultats entrats aquí (correccions
    «FCF-…» d'esports-manual.json) on la FCF encara no té l'acta tancada.
    Torna el nombre de canvis."""
    canvis = 0
    for eid, eq in EQUIPS.items():
        g = (fcf.get("grups") or {}).get(eq["grup"])
        if not g:
            continue
        actes = {}
        for llista in ((g.get("partidos") or {}).get("partidos") or {}).values():
            for m in llista or []:
                actes[str(m.get("CODACTA"))] = m
        for c in ((manual.get("equips") or {}).get(eid) or {}).get("partits", []):
            sub = str(c.get("substitueix") or "")
            if not sub.startswith("FCF-") or sub[4:] not in actes:
                continue
            m = actes[sub[4:]]
            if str(m.get("CERRADA")) == "1":
                continue
            local = str(m.get("CODEQUIPO_CASA")) == eq["codi"]
            res = re.fullmatch(r"\s*(\d+)\s*-\s*(\d+)\s*", c.get("resultat") or "")
            if res:
                nostres, seus = res.group(1), res.group(2)
                gc, gf = (nostres, seus) if local else (seus, nostres)
                if (str(m.get("GOLES_CASA")), str(m.get("GOLES_FUERA"))) != (gc, gf):
                    m["GOLES_CASA"], m["GOLES_FUERA"] = gc, gf
                    canvis += 1
                m["CERRADA"] = "1"
            if c.get("data") and re.fullmatch(r"\d{2}:\d{2}", c.get("hora") or ""):
                comienzo = f"{c['data']}T{c['hora']}:00"
                if str(m.get("COMIENZO1") or "")[:16] != comienzo[:16]:
                    m["COMIENZO1"] = comienzo
                    canvis += 1
    return canvis


def correccio(manual, eid, p, **camps):
    """Crea o actualitza la correcció d'un partit de la FCF a esports-manual.json."""
    equips = manual.setdefault("equips", {})
    e = equips.setdefault(eid, {"partits": [], "classificacio": []})
    e.setdefault("partits", [])
    clau = p["clau"]
    c = next((x for x in e["partits"] if x.get("substitueix") == clau), None)
    if not c:
        c = {"id": secrets.token_hex(5), "competicio": "", "grup": "", "jornada": str(p.get("jornada") or ""),
             "data": p.get("data") or "", "hora": p.get("hora") or "", "localVisitant": p.get("localVisitant") or "",
             "rival": p.get("rival") or "", "resultat": "", "estat": "", "camp": p.get("camp") or "",
             "nota": "Entrat des del bot latdg_infos", "substitueix": clau}
        e["partits"].append(c)
    c.update(camps)
    return c


# -----------------------------------------------------------------------------
# El bot
# -----------------------------------------------------------------------------
class Bot:
    def __init__(self, tg, gh_tauler, gh_estat):
        self.tg, self.gh, self.ghe = tg, gh_tauler, gh_estat
        self.estat, self.sha_estat, self.estat_brut = {}, None, ""
        self.esports, self.esports_quan = None, 0
        self.darrera_conciliacio = 0

    # ---- estat ----
    def carrega_estat(self):
        self.ghe.assegura_branca(ESTAT_REPO, ESTAT_BRANCA)
        d, sha = self.ghe.llegeix(ESTAT_REPO, ESTAT_CAMI, ESTAT_BRANCA)
        self.estat, self.sha_estat = d or {}, sha
        for k, v in (("offset", 0), ("accions", {}), ("preguntes", {}), ("recordatoris", {}), ("divendres", "")):
            self.estat.setdefault(k, v)
        self.estat_brut = json.dumps(self.estat, sort_keys=True)

    def desa_estat(self):
        brut = json.dumps(self.estat, sort_keys=True)
        if brut == self.estat_brut:
            return
        # Neteja: accions i preguntes de més de 10 dies.
        limit = (ara() - dt.timedelta(days=10)).isoformat()
        for k in ("accions", "preguntes"):
            self.estat[k] = {a: b for a, b in self.estat[k].items() if b.get("quan", "") >= limit}
        self.estat["recordatoris"] = {a: b for a, b in self.estat["recordatoris"].items() if b.get("quan", "") >= limit}
        try:
            self.sha_estat = self.ghe.desa(ESTAT_REPO, ESTAT_CAMI, self.estat, self.sha_estat, "Estat del bot infos", ESTAT_BRANCA)
        except Conflicte:
            _, self.sha_estat = self.ghe.llegeix(ESTAT_REPO, ESTAT_CAMI, ESTAT_BRANCA)
            self.sha_estat = self.ghe.desa(ESTAT_REPO, ESTAT_CAMI, self.estat, self.sha_estat, "Estat del bot infos", ESTAT_BRANCA)
        self.estat_brut = json.dumps(self.estat, sort_keys=True)

    def accio(self, **d):
        n = secrets.token_hex(4)
        self.estat["accions"][n] = {**d, "quan": ara().isoformat()}
        return "a:" + n

    def dades_esports(self, fresques=False):
        if fresques or not self.esports or time.time() - self.esports_quan > 300:
            self.esports, _ = self.gh.llegeix(TAULER, F_ESPORTS)
            self.esports_quan = time.time()
        return self.esports

    def partit(self, clau):
        for eid, p in partits_futbol(self.dades_esports(True)):
            if p.get("clau") == clau:
                return eid, p
        return None, None

    # ---- tasques programades ----
    def divendres(self, forcat=False):
        """Divendres a les 17 h: demana el fitxer de la FCF. La llista dels partits del cap de
        setmana (per comprovar els horaris) arriba uns minuts després de desar-lo, amb les
        dades al dia; si a les 19 h encara no ha arribat cap fitxer, s'envia igualment."""
        a = ara()
        avui = a.date().isoformat()
        if forcat:
            return self.llista_cap_de_setmana()
        if a.weekday() != 4 or a.hour < DIVENDRES_HORA:
            return
        if self.estat["divendres"] != avui:
            self.estat["divendres"] = avui
            self.estat["llista"] = {"dia": avui, "quan": (a.replace(hour=LLISTA_HORA_LIMIT, minute=0, second=0)).isoformat()}
            self.tg.envia("📥 TOCA EL FITXER DE LA FCF (horaris del cap de setmana)\n"
                          "1. Obre www.fcf.cat (al portàtil, o amb Chrome al mòbil).\n"
                          "2. Toca el marcador «Futbol → La TdG».\n"
                          "3. Envia'm el fitxer futbol-tdg.json (o puja'l a la pàgina d'esports) i toca «✅ Desa'l».\n"
                          "Uns minuts després et passaré els partits per confirmar els horaris (a les 19 h, si no "
                          "m'arriba cap fitxer).")
            return
        llista = self.estat.get("llista") or {}
        if llista.get("dia") == avui and not llista.get("fet") and a.isoformat() >= llista.get("quan", "9"):
            llista["fet"] = True
            self.llista_cap_de_setmana()

    def llista_cap_de_setmana(self):
        a = ara()
        avui = a.date().isoformat()
        fi = (a.date() + dt.timedelta(days=6 - a.weekday())).isoformat()   # fins diumenge
        partits = [(eid, p) for eid, p in partits_futbol(self.dades_esports(True))
                   if avui <= (p.get("data") or "") <= fi and not p.get("resultat")]
        if not partits:
            self.tg.envia(f"⚽ FUTBOL DEL CAP DE SETMANA\nNo hi ha cap partit de futbol previst fins a {data_ca(fi)}.")
            return
        self.tg.envia("⚽ FUTBOL DEL CAP DE SETMANA\nComprova si els horaris són correctes.")
        for eid, p in partits:
            botons = [[{"text": "✅ Correcte", "callback_data": self.accio(op="correcte", clau=p["clau"])},
                       {"text": "✏️ Canvia l'hora", "callback_data": self.accio(op="canvia", clau=p["clau"])},
                       {"text": "⏸ Ajornat", "callback_data": self.accio(op="ajornat", clau=p["clau"])}]]
            self.tg.envia(linia_partit(EQUIPS[eid]["nom"], p), botons=botons)

    def dilluns(self):
        """Cada dilluns a les 18 h: que baixi el fitxer de la FCF (classificacions i horaris)."""
        a = ara()
        avui = a.date().isoformat()
        if a.weekday() != 0 or a.hour < DILLUNS_HORA or self.estat.get("dilluns") == avui:
            return
        self.estat["dilluns"] = avui
        self.tg.envia("📥 TOCA EL FITXER DE LA FCF\nLa jornada ja és tancada. Per posar al dia les classificacions i els "
                      "horaris:\n1. Obre www.fcf.cat (al portàtil, o amb Chrome al mòbil).\n"
                      "2. Toca el marcador «Futbol → La TdG».\n"
                      "3. Envia'm el fitxer futbol-tdg.json (o puja'l a la pàgina d'esports) i toca «✅ Desa'l».")

    def recordatoris(self):
        a = ara()
        avui = a.date().isoformat()
        ara_min = a.hour * 60 + a.minute
        for eid, p in partits_futbol(self.dades_esports()):
            if p.get("data") != avui or p.get("resultat") or re.search(r"ajorn|susp", p.get("estat") or "", re.I):
                continue
            h = re.fullmatch(r"(\d{1,2}):(\d{2})", p.get("hora") or "")
            if not h:
                continue
            passat = ara_min - (int(h.group(1)) * 60 + int(h.group(2)))
            r = self.estat["recordatoris"].get(p["clau"], {"n": 0})
            if r.get("fet"):
                continue
            if (r["n"] == 0 and passat >= RESULTAT_DESPRES_MIN) or (r["n"] == 1 and passat >= RESULTAT_SEGONA_MIN):
                if passat > FINESTRA_PUBLICACIO_MIN:
                    continue
                self.pregunta_resultat(eid, p, segona=r["n"] == 1)
                self.estat["recordatoris"][p["clau"]] = {"n": r["n"] + 1, "quan": a.isoformat()}

    def pregunta_resultat(self, eid, p, segona=False):
        text = ("⚽ " + ("ENCARA FALTA EL RESULTAT" if segona else "RESULTAT?") + "\n" + linia_partit(EQUIPS[eid]["nom"], p) +
                "\n\nRespon a aquest missatge amb el marcador, el local primer (p. ex. 2-1).")
        m = self.tg.envia(text, botons=[[{"text": "⏸ Ajornat", "callback_data": self.accio(op="ajornat", clau=p["clau"])},
                                         {"text": "🚫 Suspès", "callback_data": self.accio(op="suspes", clau=p["clau"])}]])
        self.estat["preguntes"][str(m["message_id"])] = {"tipus": "resultat", "clau": p["clau"], "quan": ara().isoformat()}

    def concilia(self, forcat=False):
        if not forcat and time.time() - self.darrera_conciliacio < 600:
            return
        self.darrera_conciliacio = time.time()
        manual, _ = self.gh.llegeix(TAULER, F_MANUAL)
        if not manual:
            return
        n = {"canvis": 0}

        def canvi(fcf):
            n["canvis"] = aplica_correccions(fcf, manual)
            return n["canvis"] > 0
        if modifica(self.gh, TAULER, F_FCF, canvi, "Futbol: hores i resultats entrats al bot latdg_infos"):
            log(f"Conciliació: {n['canvis']} canvis al fitxer de la FCF.")

    # ---- missatges ----
    def missatge(self, m):
        if str((m.get("chat") or {}).get("id")) != self.tg.chat:
            return
        if m.get("document"):
            return self.document(m)
        text = (m.get("text") or "").strip()
        if not text:
            return
        if text.lower() in ("/futbol", "/start", "/ajuda"):
            if text.lower() == "/futbol":
                return self.divendres(forcat=True)
            return self.tg.envia("Aquest bot et pregunta pels partits de futbol (divendres i dia de partit) i desa el "
                                 "fitxer futbol-tdg.json del marcador de la FCF.\n/futbol: partits fins diumenge.")
        preg = None
        resp = str((m.get("reply_to_message") or {}).get("message_id") or "")
        if resp in self.estat["preguntes"]:
            preg = self.estat["preguntes"][resp]
        else:
            recents = (ara() - dt.timedelta(hours=12)).isoformat()
            obertes = [q for q in self.estat["preguntes"].values() if not q.get("tancada") and q.get("quan", "") >= recents]
            if len(obertes) == 1:
                preg = obertes[0]
            elif len(obertes) > 1:
                return self.tg.envia("Tinc més d'una pregunta oberta: respon directament al missatge del partit "
                                     "(mantén-lo premut i toca «Respon»).")
        if not preg:
            return
        eid, p = self.partit(preg["clau"])
        if not p:
            return self.tg.envia("No trobo aquest partit al calendari del tauler.")
        nom = EQUIPS[eid]["nom"]
        if preg["tipus"] == "resultat":
            if re.fullmatch(r"ajorna[td]\w*", text.lower()):
                return self.posa_estat(eid, p, "Ajornat")
            if re.fullmatch(r"susp[eè]s\w*", text.lower()):
                return self.posa_estat(eid, p, "Suspès")
            marcador = llegeix_marcador(text)
            if not marcador:
                return self.tg.envia("No l'entenc. Escriu només el marcador, el local primer: p. ex. 2-1.")
            gl, gv = marcador
            local_nom, visit_nom = (nom.upper(), p["rival"]) if p.get("localVisitant") == "Local" else (p["rival"], nom.upper())
            self.tg.envia(f"{local_nom} {gl} - {gv} {visit_nom}\nÉs correcte?", botons=[[
                {"text": "✅ Publica", "callback_data": self.accio(op="resultat", clau=p["clau"], gl=gl, gv=gv)},
                {"text": "↩️ Torna-hi", "callback_data": self.accio(op="torna", clau=p["clau"], tipus="resultat")}]])
        elif preg["tipus"] == "hora":
            nova = llegeix_hora(text, p.get("data"))
            if not nova:
                return self.tg.envia("No l'entenc. Escriu la data i l'hora (14.11 18.30) o només l'hora (18.30).")
            data, hora = nova
            self.tg.envia(f"{nom}: {nom_partit(nom, p)}\nNou horari: {data_ca(data)}, {hora_ca(hora)}. És correcte?", botons=[[
                {"text": "✅ Desa", "callback_data": self.accio(op="hora", clau=p["clau"], data=data, hora=hora)},
                {"text": "↩️ Torna-hi", "callback_data": self.accio(op="torna", clau=p["clau"], tipus="hora")}]])

    def document(self, m):
        doc = m["document"]
        nom = doc.get("file_name") or "fitxer"
        if not nom.lower().endswith(".json") or (doc.get("file_size") or 0) > 5_000_000:
            return self.tg.envia(f"He rebut «{nom}», però aquest bot només fa servir el fitxer futbol-tdg.json "
                                 "del marcador «Futbol → La TdG».")
        try:
            f = json.loads(self.tg.baixa(doc["file_id"]).decode("utf-8-sig"))
        except Exception as e:
            log("⚠️ baixada del fitxer:", type(e).__name__, str(e)[:160])
            return self.tg.envia(f"❌ No he pogut llegir «{nom}» ({type(e).__name__}: {amaga(e)[:120]}). "
                                 "Torna-ho a provar d'aquí a un moment o puja'l a la pàgina d'esports: " + PAGINA)
        if not fitxer_valid(f):
            return self.tg.envia(f"«{nom}» no és el fitxer del marcador de la FCF (futbol-tdg.json).")
        try:
            g = dt.datetime.fromisoformat(str(f.get("generat")).replace("Z", "+00:00")).astimezone(TZ)
            quan = f"el {g.strftime('%d.%m.%Y')} a les {g.strftime('%H.%M')} h"
        except ValueError:
            quan = "(sense data)"
        text = f"⚽ Fitxer de la FCF baixat {quan}:\n\n" + "\n".join("• " + l for l in resum_fcf(f, ara().date().isoformat()))
        self.tg.envia(text, botons=[[{"text": "✅ Desa'l", "callback_data": self.accio(op="desa_fcf", file_id=doc["file_id"])},
                                     {"text": "✖️ Descarta", "callback_data": self.accio(op="descarta")}]],
                      respon_a=m.get("message_id"))

    # ---- botons ----
    def boto(self, q):
        if str(((q.get("message") or {}).get("chat") or {}).get("id")) != self.tg.chat:
            return
        dada = str(q.get("data") or "")
        acc = self.estat["accions"].get(dada[2:]) if dada.startswith("a:") else None
        missatge_id = (q.get("message") or {}).get("message_id")
        text_original = (q.get("message") or {}).get("text") or ""
        if not acc:
            self.tg.respon_boto(q["id"], "Aquest botó ja no és vàlid.")
            return
        if acc.get("fet"):
            self.tg.respon_boto(q["id"], "Ja està fet.")
            return
        op = acc["op"]
        self.tg.respon_boto(q["id"])
        if op == "descarta":
            acc["fet"] = True
            return self.tg.edita(missatge_id, text_original + "\n\n✖️ Descartat.")
        if op == "desa_fcf":
            try:
                f = json.loads(self.tg.baixa(acc["file_id"]).decode("utf-8"))
                manual, _ = self.gh.llegeix(TAULER, F_MANUAL)
                if not fitxer_valid(f):
                    raise ValueError("fitxer no vàlid")
                aplica_correccions(f, manual or {})
                def substitueix(d):
                    d.clear()
                    d.update(f)
                modifica(self.gh, TAULER, F_FCF, substitueix, "Futbol: fitxer de la FCF enviat al bot latdg_infos",
                         perdefecte={})
            except Exception as e:
                log("⚠️ desa_fcf:", type(e).__name__, str(e)[:160])
                return self.tg.envia("❌ No s'ha pogut desar. Puja el fitxer a la pàgina d'esports: " + PAGINA)
            acc["fet"] = True
            llista = self.estat.get("llista") or {}
            if llista.get("dia") == ara().date().isoformat() and not llista.get("fet"):
                llista["quan"] = (ara() + dt.timedelta(minutes=LLISTA_ESPERA_MIN)).isoformat()
            return self.tg.edita(missatge_id, text_original + "\n\n✅ Desat. En un parell de minuts, el tauler, el guió "
                                 "i l'avisador ja van amb aquestes dades.")
        eid, p = self.partit(acc.get("clau"))
        if not p:
            return self.tg.envia("No trobo aquest partit al calendari del tauler.")
        nom = EQUIPS[eid]["nom"]
        if op == "correcte":
            acc["fet"] = True
            return self.tg.edita(missatge_id, text_original + "\n✅ Correcte")
        if op == "canvia" or (op == "torna" and acc.get("tipus") == "hora"):
            m = self.tg.envia(f"✏️ {nom}: {nom_partit(nom, p)}\nAra: {data_ca(p.get('data'))}, {hora_ca(p.get('hora'))}.\n"
                              "Respon amb el nou horari: data i hora (14.11 18.30) o només l'hora (18.30).",
                              resposta_forcada=True)
            self.estat["preguntes"][str(m["message_id"])] = {"tipus": "hora", "clau": p["clau"], "quan": ara().isoformat()}
            return
        if op == "torna":
            return self.pregunta_resultat(eid, p)
        if op in ("ajornat", "suspes"):
            acc["fet"] = True
            self.posa_estat(eid, p, "Ajornat" if op == "ajornat" else "Suspès")
            return self.tg.edita(missatge_id, text_original + ("\n⏸ Ajornat" if op == "ajornat" else "\n🚫 Suspès"))
        if op == "hora":
            self.desa_correccio(eid, p, "Futbol: horari corregit al bot latdg_infos", data=acc["data"], hora=acc["hora"])
            acc["fet"] = True
            self.tanca_preguntes(p["clau"], "hora")
            return self.tg.edita(missatge_id, text_original.replace("És correcte?", "").rstrip() +
                                 "\n✅ Desat: el tauler i el guió ja hi van amb aquest horari.")
        if op == "resultat":
            gl, gv = int(acc["gl"]), int(acc["gv"])
            local = p.get("localVisitant") == "Local"
            nostres, seus = (gl, gv) if local else (gv, gl)
            self.desa_correccio(eid, p, "Futbol: resultat entrat al bot latdg_infos",
                                resultat=f"{nostres} - {seus}", estat="Finalitzat")
            acc["fet"] = True
            self.tanca_preguntes(p["clau"], "resultat")
            self.estat["recordatoris"][p["clau"]] = {"n": 9, "fet": True, "quan": ara().isoformat()}
            fcf_ok = self.posa_a_fcf(eid, p)
            h = re.fullmatch(r"(\d{1,2}):(\d{2})", p.get("hora") or "")
            fora = False
            if h and p.get("data"):
                inici = dt.datetime.fromisoformat(f"{p['data']}T{int(h.group(1)):02d}:{h.group(2)}").replace(tzinfo=TZ)
                fora = ara() > inici + dt.timedelta(minutes=FINESTRA_PUBLICACIO_MIN)
            if not fcf_ok:
                avis = ("\n⚠️ Encara no hi ha cap fitxer de la FCF pujat i el bot de La Torre de Guaita no el pot publicar. "
                        "Envia'm el fitxer del marcador «Futbol → La TdG» i el publicarà.")
            elif fora:
                avis = "\n⚠️ Han passat més de 8 hores de l'inici: el bot de La Torre de Guaita ja no el publicarà sol."
            else:
                avis = "\nEl bot de La Torre de Guaita el publicarà al canal en el proper quart d'hora."
            return self.tg.edita(missatge_id, text_original.replace("És correcte?", "").rstrip() +
                                 "\n✅ Desat al tauler i al guió." + avis)

    def tanca_preguntes(self, clau, tipus):
        for q in self.estat["preguntes"].values():
            if q.get("clau") == clau and q.get("tipus") == tipus:
                q["tancada"] = True

    def posa_estat(self, eid, p, estat):
        self.desa_correccio(eid, p, f"Futbol: partit {estat.lower()} (bot latdg_infos)", estat=estat)
        self.tanca_preguntes(p["clau"], "resultat")
        self.estat["recordatoris"][p["clau"]] = {"n": 9, "fet": True, "quan": ara().isoformat()}
        self.tg.envia(f"{'⏸' if estat == 'Ajornat' else '🚫'} {EQUIPS[eid]['nom']}: {nom_partit(EQUIPS[eid]['nom'], p)} "
                      f"queda com a {estat.lower()} al tauler i al guió.")

    def desa_correccio(self, eid, p, missatge, **camps):
        def canvi(man):
            correccio(man, eid, p, **camps)
        modifica(self.gh, TAULER, F_MANUAL, canvi, missatge, perdefecte={"nota": "", "equips": {}})

    def posa_a_fcf(self, eid, p):
        manual, _ = self.gh.llegeix(TAULER, F_MANUAL)
        resultat = {"ok": False}

        def canvi(fcf):
            resultat["ok"] = True
            return aplica_correccions(fcf, manual or {}) > 0
        modifica(self.gh, TAULER, F_FCF, canvi, "Futbol: resultat entrat al bot latdg_infos")
        return resultat["ok"]

    # ---- bucle ----
    def bucle(self):
        self.carrega_estat()
        fi = time.time() + DURADA
        errors = 0
        while time.time() < fi:
            try:
                for u in self.tg._updates(self.estat["offset"]):
                    self.estat["offset"] = u["update_id"] + 1
                    try:
                        if "callback_query" in u:
                            self.boto(u["callback_query"])
                        elif "message" in u:
                            self.missatge(u["message"])
                    except Exception as e:
                        log("⚠️ actualització:", type(e).__name__, str(e)[:100])
                        try:
                            self.tg.envia("❌ Alguna cosa no ha anat bé. Torna-ho a provar d'aquí a un moment "
                                          "o fes-ho a la pàgina d'esports: " + PAGINA)
                        except Exception:
                            pass
                self.divendres()
                self.dilluns()
                self.recordatoris()
                self.concilia()
                self.desa_estat()
                errors = 0
            except Exception as e:
                errors += 1
                log("⚠️ bucle:", type(e).__name__, str(e)[:120])
                if "409" in str(e):
                    log("Un altre procés llegeix el bot (o hi ha un webhook): m'aturo.")
                    sys.exit(1)   # sense tornar-se a llançar (ho reprèn l'horari)
                time.sleep(min(60, 5 * errors))
        self.desa_estat()


# -----------------------------------------------------------------------------
# Proves sense xarxa
# -----------------------------------------------------------------------------
def proves():
    assert llegeix_marcador("2-1") == (2, 1) and llegeix_marcador(" 10 – 0 ") == (10, 0) and llegeix_marcador("2 a 1") is None
    assert llegeix_hora("18.30", "2026-11-15") == ("2026-11-15", "18:30")
    assert llegeix_hora("ds 14.11 18:30", "2026-11-15") == ("2026-11-14", "18:30")
    assert llegeix_hora("14.11.2026 9.05", "2026-11-15") == ("2026-11-14", "09:05")
    assert llegeix_hora("25.30", "2026-11-15") is None
    p = {"clau": "FCF-100", "data": "2026-11-15", "hora": "16:30", "localVisitant": "Visitant", "rival": "SANTJOANENC",
         "jornada": "10", "camp": "CAMP"}
    man = {"equips": {}}
    correccio(man, "atletic_bisbalenc", p, resultat="1 - 3", estat="Finalitzat")
    fcf = {"tipus": "latdg-fcf", "grups": {"58161863": {"partidos": {"partidos": {"10": [
        {"CODACTA": "100", "CODEQUIPO_CASA": "999", "CODEQUIPO_FUERA": "33220", "GOLES_CASA": None, "GOLES_FUERA": None,
         "CERRADA": "0", "COMIENZO1": "2026-11-15T16:30:00"}]}}, "classificacio": {"data": []}}}}
    assert fitxer_valid(fcf)
    assert aplica_correccions(fcf, man) == 1
    m = fcf["grups"]["58161863"]["partidos"]["partidos"]["10"][0]
    assert (m["GOLES_CASA"], m["GOLES_FUERA"], m["CERRADA"]) == ("3", "1", "1"), m   # visitant: 1 nostre, 3 seus
    assert aplica_correccions(fcf, man) == 0                                          # acta tancada: no es toca
    correccio(man, "atletic_bisbalenc", p, data="2026-11-15", hora="18:00")
    assert len(man["equips"]["atletic_bisbalenc"]["partits"]) == 1
    assert nom_partit("Atlètic Bisbalenc", p) == "SANTJOANENC – ATLÈTIC BISBALENC"
    print("Proves: totes bé.")


def main():
    if "--prova" in sys.argv:
        return proves()
    arg = lambda n: sys.argv[sys.argv.index(n) + 1]
    props = json.load(open(arg("--props")))["props"]
    props_esports = json.load(open(arg("--props-esports")))["props"]
    tg = Telegram(props["TELEGRAM_BOT_TOKEN_INFOS"].strip(), props["TELEGRAM_CHAT_ID_INFOS"].strip())
    bot = Bot(tg, GitHub(props_esports["TAULER_GITHUB_TOKEN"].strip()), GitHub(os.environ["APPS_SCRIPT_TOKEN"]))
    log("Bot latdg_infos (futbol) en marxa.")
    bot.bucle()


if __name__ == "__main__":
    main()
