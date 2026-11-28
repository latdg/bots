# =============================================================================
# AGENDA DE L'AGUAIT → AGENDA DE LA TdG AMPLIADA — La TdG · 28.11.2026
#
# Mòdul del bot latdg_infos (bot_infos.py). Cada 30 minuts, de 7 a 23 h:
#  1. Llegeix els actes nous de laguait.cat/agenda (API de WordPress, tipus
#     «mec-events» de Modern Events Calendar) i, de cada un, l'iCal
#     (dia, hora i lloc). Els actes que ja han passat no es tenen en compte.
#  2. Els compara amb dades/agenda.json (latdg/tauler) el mateix dia:
#     hora propera (fins a 1 h 30 min de diferència, o sense hora) i, sobretot,
#     la mateixa temàtica (paraules del títol, amb més pes per als noms propis).
#       · Ja hi és     → no s'hi afegeix. Botó «➕ Afegeix-lo igualment».
#       · Nou          → s'hi afegeix. Botó «↩️ Treu-lo de l'agenda».
#       · Dubtós       → no s'hi afegeix i pregunta: «➕ Afegeix-lo» / «✖️ No».
#  3. Correu a latdg@laguait.cat amb el resum de cada ronda, si el workflow té
#     els secrets SMTP_USUARI i SMTP_CONTRASENYA (contrasenya d'aplicació de
#     Gmail). Sense secrets, només va per Telegram.
#
#   python agenda_aguait.py --prova     (proves sense xarxa)
# =============================================================================
import datetime as dt
import html
import os
import re
import smtplib
import unicodedata
from email.mime.text import MIMEText
from zoneinfo import ZoneInfo

import requests

TZ = ZoneInfo("Europe/Madrid")
API = "https://laguait.cat/wp-json/wp/v2/mec-events"
ICAL = "https://laguait.cat/?method=ical&id={id}"
TAULER = "latdg/tauler"
F_AGENDA = "dades/agenda.json"
PAGINA_AGENDA = "https://latdg.github.io/tauler/agenda/"
CORREU_A = "latdg@laguait.cat"
CADA_MIN = 30
HORES = (7, 23)
MARGE_HORA_MIN = 90
CAP = {"User-Agent": "Mozilla/5.0 (La TdG; latdg@laguait.cat)"}

MUNICIPIS = [   # nucli que pot sortir al lloc → valor del camp «municipi» de l'agenda
    ("sant sadurni de l'heura", "Sant Sadurní de l'Heura"), ("sant climent de peralta", "Sant Climent de Peralta"),
    ("cassa de pelras", "Cassà de Pelràs"), ("peratallada", "Peratallada"), ("vulpellac", "Vulpellac"),
    ("canapost", "Canapost"), ("fonteta", "Fonteta"), ("monells", "Monells"), ("cruilles", "Cruïlles"),
    ("casavells", "Casavells"), ("corca", "Corçà"), ("ullastret", "Ullastret"), ("forallac", "Forallac"),
    ("la bisbal", "La Bisbal"), ("bisbal", "La Bisbal"),
]
BUIDES = set("""a al als amb an aquest aquesta aquests aquestes de del dels des el els en entre es et i la les lo
li per pel pels que qui se sense si sobre son un una uns unes o hi ha seu seva seus seves cap fins tot tota tots
totes dia dies dins mes hora hores h nou nova primer primera segon segona presenta presenten presentacio acte
actes activitat organitza organitzat marc edicio llibre""".split())
GENERIQUES = set("""concert concerts xerrada conferencia taller cinema projeccio teatre espectacle exposicio
inauguracio jornada debat festa fira mercat visita guiada sopar dinar ballada sardanes nadal bisbal""".split())


def _sense_accents(s):
    return "".join(c for c in unicodedata.normalize("NFD", str(s)) if unicodedata.category(c) != "Mn")


def _norm(s):
    s = _sense_accents(s).lower().replace("l·l", "ll").replace("’", "'")
    return re.sub(r"[^a-z0-9' ]+", " ", s)


def _arrel(w):
    return w[:5] if len(w) >= 5 else w


def paraules(text):
    """Paraules significatives (arrel) i quines són noms propis (majúscula enmig del text)."""
    totes, propis = set(), set()
    for i, w in enumerate(re.findall(r"[\wÀ-ÿ·']+", str(text))):
        w = re.sub(r"^(l|d|s|n|m)'", "", w, flags=re.I)
        n = _norm(w).strip("' ")
        if len(n) < 3 or n in BUIDES or n.isdigit():
            continue
        a = _arrel(n)
        totes.add(a)
        if i > 0 and w[:1].isupper() and n not in GENERIQUES:
            propis.add(a)
    return totes, propis


def minuts(hora):
    m = re.search(r"(\d{1,2})[.:,](\d{2})", str(hora or ""))
    return int(m.group(1)) * 60 + int(m.group(2)) if m else None


def municipi_de(lloc, titol=""):
    t = _norm(lloc + " " + titol)
    for clau, nom in MUNICIPIS:
        if clau in t:
            return nom
    return "La Bisbal"


def compara(nou, acte):
    """Puntuació de temàtica (0-1), noms propis compartits i si l'hora és propera."""
    tn, pn = paraules(nou["titol"])
    ta, _ = paraules(acte.get("text", "") + " " + acte.get("municipi", ""))
    if not tn:
        return 0.0, 0, False
    comunes = tn & ta
    especifiques = {w for w in tn if w not in {_arrel(g) for g in GENERIQUES}}
    pes = lambda c: sum(2 if w in pn else 1 for w in c)
    puntuacio = pes(comunes) / max(1, pes(tn))
    propis = len(comunes & pn)
    mn, ma = minuts(nou["hora"]), minuts(acte.get("hora"))
    prop = mn is None or ma is None or abs(mn - ma) <= MARGE_HORA_MIN
    if not (comunes & especifiques):   # només coincideixen paraules genèriques (concert, xerrada…)
        puntuacio = min(puntuacio, 0.3)
    return puntuacio, propis, prop


def decideix(nou, actes):
    """('repetit'|'dubtos'|'nou', acte de l'agenda més semblant o None)."""
    millor, millor_p = None, (-1, 0, False)
    for a in actes:
        if a.get("data") != nou["data"]:
            continue
        p = compara(nou, a)
        if (p[0], p[1]) > (millor_p[0], millor_p[1]):
            millor, millor_p = a, p
    if not millor:
        return "nou", None
    puntuacio, propis, prop = millor_p
    if (puntuacio >= 0.5 or propis >= 1) and prop:
        return "repetit", millor
    if puntuacio >= 0.5 or propis >= 1 or (puntuacio >= 0.2 and prop):
        return "dubtos", millor
    return "nou", None


# -----------------------------------------------------------------------------
# Lectura de L'Aguait
# -----------------------------------------------------------------------------
def _ical_valor(ics, nom):
    m = re.search(r"^" + nom + r"((?:;[^:\r\n]*)?):(.*(?:\r?\n[ \t].*)*)", ics, re.M)
    if not m:
        return None, None
    valor = re.sub(r"\r?\n[ \t]", "", m.group(2)).strip()
    valor = valor.replace("\\n", "\n").replace("\\N", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")
    return m.group(1), valor


def _ical_data(params, valor):
    if not valor:
        return None, False
    if re.fullmatch(r"\d{8}", valor) or "VALUE=DATE" in (params or "").upper() and len(valor) == 8:
        return dt.datetime.strptime(valor[:8], "%Y%m%d").replace(tzinfo=TZ), True
    d = dt.datetime.strptime(valor[:15], "%Y%m%dT%H%M%S")
    if valor.endswith("Z"):
        return d.replace(tzinfo=dt.timezone.utc).astimezone(TZ), False
    return d.replace(tzinfo=TZ), False


def llegeix_ical(text):
    pi, vi = _ical_valor(text, "DTSTART")
    pf, vf = _ical_valor(text, "DTEND")
    inici, tot_el_dia = _ical_data(pi, vi)
    fi, _ = _ical_data(pf, vf)
    _, lloc = _ical_valor(text, "LOCATION")
    _, desc = _ical_valor(text, "DESCRIPTION")
    _, titol = _ical_valor(text, "SUMMARY")
    return {"inici": inici, "fi": fi, "tot_el_dia": tot_el_dia, "lloc": lloc or "", "descripcio": desc or "",
            "titol": titol or ""}


def llegeix_pagina(text):
    """Si l'iCal no va: data i hora de l'enllaç de Google Calendar i lloc de la fitxa."""
    m = re.search(r"dates=(\d{8}T\d{6}Z?)", text)
    inici = _ical_data("", m.group(1))[0] if m else None
    lloc = ""
    l = re.search(r'mec-single-event-location.*?<(?:h6|dd|span)[^>]*>(.*?)</', text, re.S)
    if l:
        lloc = html.unescape(re.sub(r"<[^>]+>", "", l.group(1))).strip()
    return {"inici": inici, "fi": None, "tot_el_dia": False, "lloc": lloc, "descripcio": "", "titol": ""}


def text_net(s):
    s = html.unescape(re.sub(r"<[^>]+>", " ", str(s or "")))
    return re.sub(r"\s+", " ", s).strip()


def acte_de(post, det):
    titol = text_net((post.get("title") or {}).get("rendered")) or det["titol"]
    inici = det["inici"]
    hora = "" if det["tot_el_dia"] or (inici.hour == 0 and inici.minute == 0) else inici.strftime("%H.%M") + " h"
    lloc = text_net(det["lloc"])
    desc = text_net(det["descripcio"] or (post.get("content") or {}).get("rendered") or "")
    if desc.lower().startswith(titol.lower()):
        desc = desc[len(titol):].lstrip(" .:-")
    if len(desc) > 500:
        tall = desc[:500]
        desc = tall[:tall.rfind(". ") + 1] if ". " in tall else tall.rsplit(" ", 1)[0] + "…"
    text = titol.rstrip(".") + (" (" + lloc + ")" if lloc and _norm(lloc) not in _norm(titol) else "") + "."
    fi = det.get("fi")
    if fi and fi.date() > inici.date():
        text += " Fins " + ("a l'" if fi.day in (1, 11) else "al ") + fi.strftime("%d.%m.%Y") + "."
    if desc:
        text += " " + desc
    return {"data": inici.date().isoformat(), "hora": hora, "municipi": municipi_de(lloc, titol), "text": text,
            "titol": titol, "lloc": lloc, "enllac": post.get("link") or ""}


def actes_nous(vistos):
    r = requests.get(API, params={"per_page": 20, "orderby": "date", "order": "desc",
                                  "_fields": "id,date,title,link,content"}, headers=CAP, timeout=40)
    r.raise_for_status()
    surt = []
    for post in r.json():
        pid = str(post.get("id"))
        if pid in vistos:
            continue
        det = None
        try:
            ri = requests.get(ICAL.format(id=pid), headers=CAP, timeout=30)
            if ri.ok and "BEGIN:VEVENT" in ri.text:
                det = llegeix_ical(ri.text)
        except (requests.RequestException, ValueError):
            det = None
        if not det or not det["inici"]:
            try:
                rp = requests.get(post.get("link"), headers=CAP, timeout=30)
                det = llegeix_pagina(rp.text) if rp.ok else None
            except requests.RequestException:
                det = None
        if not det or not det["inici"]:
            continue   # es tornarà a provar a la ronda següent
        surt.append((pid, acte_de(post, det)))
    return surt


# -----------------------------------------------------------------------------
# Correu i textos
# -----------------------------------------------------------------------------
def data_ca(iso):
    d = dt.date.fromisoformat(iso)
    return ["Dilluns", "Dimarts", "Dimecres", "Dijous", "Divendres", "Dissabte", "Diumenge"][d.weekday()] + " " + \
        d.strftime("%d.%m.%Y")


def fitxa(a):
    return f"{data_ca(a['data'])}{', ' + a['hora'] if a.get('hora') else ''} · {a.get('municipi', '')}\n{a.get('text', '')}"


def envia_correu(linies, log):
    usuari, clau = os.environ.get("SMTP_USUARI", "").strip(), os.environ.get("SMTP_CONTRASENYA", "").strip()
    if not (usuari and clau) or not linies:
        return
    cos = "Actes nous a l'agenda de L'Aguait (laguait.cat/agenda):\n\n" + "\n\n".join(linies) + \
          f"\n\nAgenda de La TdG ampliada: {PAGINA_AGENDA}\n"
    msg = MIMEText(cos, "plain", "utf-8")
    msg["Subject"] = f"Agenda de L'Aguait: {len(linies)} acte{'s' if len(linies) > 1 else ''} nou{'s' if len(linies) > 1 else ''}"
    msg["From"], msg["To"] = f"La TdG <{usuari}>", CORREU_A
    try:
        with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=40) as s:
            s.login(usuari, clau)
            s.sendmail(usuari, [CORREU_A], msg.as_string())
    except Exception as e:   # el correu no ha d'aturar el bot
        log("⚠️ correu de l'agenda:", type(e).__name__)


# -----------------------------------------------------------------------------
# Integració amb el bot
# -----------------------------------------------------------------------------
def net_per_agenda(a, aid):
    return {"id": aid, "data": a["data"], "hora": a["hora"], "municipi": a["municipi"], "text": a["text"][:3000]}


def afegeix(bot, a, aid, modifica):
    def canvi(ag):
        actes = ag.setdefault("actes", [])
        if any(x.get("id") == aid for x in actes):
            return False
        actes.append(net_per_agenda(a, aid))
        actes.sort(key=lambda x: x.get("data", "") + (x.get("hora") or "99"))
        ag["actualitzat"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    modifica(bot.gh, TAULER, F_AGENDA, canvi, "Agenda: acte de L'Aguait (" + a["data"] + ")", perdefecte={"actes": []})


def treu(bot, aid, modifica):
    def canvi(ag):
        abans = len(ag.get("actes", []))
        ag["actes"] = [x for x in ag.get("actes", []) if x.get("id") != aid]
        if len(ag["actes"]) == abans:
            return False
        ag["actualitzat"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    return modifica(bot.gh, TAULER, F_AGENDA, canvi, "Agenda: acte de L'Aguait tret des del bot latdg_infos")


def ronda(bot, modifica, log, forcat=False):
    """Es crida a cada volta del bucle del bot; només treballa cada 30 minuts, de 7 a 23 h."""
    est = bot.estat.setdefault("aguait", {"vistos": {}, "darrera": ""})
    ara = dt.datetime.now(TZ)
    if not forcat:
        if not (HORES[0] <= ara.hour < HORES[1]):
            return
        if est.get("darrera") and ara - dt.datetime.fromisoformat(est["darrera"]) < dt.timedelta(minutes=CADA_MIN):
            return
    est["darrera"] = ara.isoformat()
    try:
        nous = actes_nous(est["vistos"])
    except Exception as e:
        log("⚠️ agenda de L'Aguait:", type(e).__name__, str(e)[:100])
        return
    if not nous:
        return
    agenda, _ = bot.gh.llegeix(TAULER, F_AGENDA)
    actes = (agenda or {}).get("actes", [])
    avui = ara.date().isoformat()
    correu = []
    for pid, a in nous:
        est["vistos"][pid] = ara.isoformat()
        if a["data"] < avui:
            continue
        aid = "aguait" + pid
        if any(x.get("id") == aid for x in actes):
            continue
        veredicte, igual = decideix(a, actes)
        cap = f"📅 AGENDA DE L'AGUAIT\n{fitxa(a)}\n{a['enllac']}"
        dades = {"acte": net_per_agenda(a, aid)}
        if veredicte == "repetit":
            bot.tg.envia(cap + f"\n\n⏭ No l'he afegit: ja hi és.\n{fitxa(igual)}",
                         botons=[[{"text": "➕ Afegeix-lo igualment", "callback_data": bot.accio(op="ag_afegeix", **dades)}]])
            correu.append(f"• JA HI ERA (no afegit)\n{fitxa(a)}\n{a['enllac']}\n  A l'agenda: {fitxa(igual)}")
        elif veredicte == "dubtos":
            bot.tg.envia(cap + f"\n\n❓ No sé si és el mateix que aquest, que ja hi és:\n{fitxa(igual)}\n\nL'afegeixo?",
                         botons=[[{"text": "➕ Afegeix-lo", "callback_data": bot.accio(op="ag_afegeix", **dades)},
                                  {"text": "✖️ No l'afegeixis", "callback_data": bot.accio(op="descarta")}]])
            correu.append(f"• DUBTÓS (pendent al bot latdg_infos)\n{fitxa(a)}\n{a['enllac']}\n  Potser és: {fitxa(igual)}")
        else:
            try:
                afegeix(bot, a, aid, modifica)
            except Exception as e:
                log("⚠️ agenda (afegeix):", type(e).__name__, str(e)[:100])
                del est["vistos"][pid]   # es torna a provar a la ronda següent
                continue
            actes.append(net_per_agenda(a, aid))
            bot.tg.envia(cap + "\n\n✅ Afegit a l'agenda de La TdG ampliada.",
                         botons=[[{"text": "↩️ Treu-lo de l'agenda", "callback_data": bot.accio(op="ag_treu", id=aid)}]])
            correu.append(f"• AFEGIT\n{fitxa(a)}\n{a['enllac']}")
    # Només es guarden els darrers 300 actes vistos.
    if len(est["vistos"]) > 300:
        est["vistos"] = dict(sorted(est["vistos"].items(), key=lambda kv: kv[1])[-300:])
    envia_correu(correu, log)


def boto(bot, acc, missatge_id, text_original, modifica):
    """Botons «ag_…». Torna True si l'ha atès."""
    op = acc.get("op")
    if op == "ag_afegeix":
        a = acc["acte"]
        def canvi(ag):
            actes = ag.setdefault("actes", [])
            if any(x.get("id") == a["id"] for x in actes):
                return False
            actes.append(a)
            actes.sort(key=lambda x: x.get("data", "") + (x.get("hora") or "99"))
            ag["actualitzat"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        modifica(bot.gh, TAULER, F_AGENDA, canvi, "Agenda: acte de L'Aguait afegit des del bot latdg_infos",
                 perdefecte={"actes": []})
        acc["fet"] = True
        bot.tg.edita(missatge_id, text_original + "\n\n✅ Afegit a l'agenda de La TdG ampliada.")
        return True
    if op == "ag_treu":
        treu(bot, acc["id"], modifica)
        acc["fet"] = True
        bot.tg.edita(missatge_id, text_original.replace("✅ Afegit a l'agenda de La TdG ampliada.", "").rstrip() +
                     "\n\n↩️ Tret de l'agenda.")
        return True
    return False


# -----------------------------------------------------------------------------
# Proves sense xarxa
# -----------------------------------------------------------------------------
def proves():
    agenda = [
        {"id": "hq4altfpnz", "data": "2026-12-12", "hora": "18.00 h", "municipi": "Monells",
         "text": "Concert de Nadal a l'església de Sant Genís amb el cor Geriona. L'activitat està organitzada per "
                 "l'Associació Espai Cultural Can Geronès, de Monells. L'entrada és lliure."},
        {"id": "71iqodtpz7", "data": "2026-12-04", "hora": "20.00 h", "municipi": "La Bisbal",
         "text": "Carles Rebassa, poeta i narrador, presentarà la novel·la *Prometeu de mil maneres*, premi Sant Jordi "
                 "2026 atorgat per Òmnium, acompanyat de la poetessa, rapsoda i traductora Odile Arqué."},
        {"id": "7znw7vjb2n", "data": "2026-12-08", "hora": "18.00 h", "municipi": "La Bisbal",
         "text": "*Yes Nadal!* a càrrec de *Yes the music*, al teatre Mundial amb la col·laboració dels Pastorets."},
    ]
    n = lambda t, d, h: {"titol": t, "data": d, "hora": h}
    assert decideix(n("Concert de Nadal amb Geriona", "2026-12-12", "18.00 h"), agenda)[0] == "repetit"
    assert decideix(n("Carles Rebassa i Odile Arqué presenten 'Prometeu de mil maneres'", "2026-12-04", "20.00 h"),
                    agenda)[0] == "repetit"
    assert decideix(n("Concert de Nadal amb Geriona", "2026-12-13", "18.00 h"), agenda)[0] == "nou"   # altre dia
    assert decideix(n("Cinexic: 'Astres immòbils'", "2026-12-08", "20.00 h"), agenda)[0] == "nou"     # altra temàtica
    assert decideix(n("Concert de la coral del Casino", "2026-12-08", "18.30 h"), agenda)[0] == "nou"  # només «concert»
    assert decideix(n("Yes the music: concert de Nadal", "2026-12-08", "21.30 h"), agenda)[0] == "dubtos"  # hora lluny
    ics = ("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20261212T170000Z\r\nDTEND:20261212T170000Z\r\n"
           "SUMMARY:Concert de Nadal amb Geriona\r\nLOCATION:Església de Sant Genís de Monells\r\n"
           "DESCRIPTION:El cor Geriona ofereix el concert\\, amb entrada lliure.\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
    d = llegeix_ical(ics)
    assert d["inici"].strftime("%Y-%m-%d %H.%M") == "2026-12-12 18.00", d
    assert d["lloc"] == "Església de Sant Genís de Monells"
    d2 = llegeix_ical("DTSTART;TZID=Europe/Madrid:20261204T200000\nDTEND;TZID=Europe/Madrid:20261206T220000\nSUMMARY:X\n")
    assert d2["inici"].hour == 20 and d2["fi"].day == 6
    d3 = llegeix_ical("DTSTART;VALUE=DATE:20261205\nSUMMARY:Mercat\n")
    assert d3["tot_el_dia"]
    a = acte_de({"title": {"rendered": "Concert de Nadal amb Geriona"}, "link": "https://laguait.cat/agenda/x/"}, d)
    assert a == {"data": "2026-12-12", "hora": "18.00 h", "municipi": "Monells",
                 "text": "Concert de Nadal amb Geriona (Església de Sant Genís de Monells). El cor Geriona ofereix el "
                         "concert, amb entrada lliure.", "titol": "Concert de Nadal amb Geriona",
                 "lloc": "Església de Sant Genís de Monells", "enllac": "https://laguait.cat/agenda/x/"}, a
    a2 = acte_de({"title": {"rendered": "Fira"}, "link": ""}, d2)
    assert a2["text"] == "Fira. Fins al 06.12.2026.", a2["text"]
    assert municipi_de("Teatre Mundial, la Bisbal") == "La Bisbal" and municipi_de("Sala de Corçà") == "Corçà"
    p = llegeix_pagina('<a href="https://calendar.google.com/calendar/render?action=TEMPLATE&text=X&dates='
                       '20261212T170000Z/20261212T170000Z">G</a><div class="mec-single-event-location"><i></i>'
                       '<h6>Església de Sant Genís de Monells</h6></div>')
    assert p["inici"].hour == 18 and p["lloc"] == "Església de Sant Genís de Monells", p
    print("Proves de l'agenda de L'Aguait: totes bé.")


if __name__ == "__main__":
    import sys
    if "--prova" in sys.argv:
        proves()
