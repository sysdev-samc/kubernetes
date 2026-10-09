#!/usr/bin/env python3
# TOP DES MACHINES QUI ENVOIENT LE PLUS VERS INTERNET (lecture seule, ne modifie rien).
# Source : ntopng (Docker sur nas2), qui écoute le port miroir de la fibre (enp1s0) :
# tout ce qu'il voit passe par la box, donc "envoyé" = upload vers Internet.
#
# Usage : python3 /ssd1/kubernetes/reseau/top-sortants.py                   # aujourd'hui depuis minuit
#         python3 /ssd1/kubernetes/reseau/top-sortants.py hier
#         python3 /ssd1/kubernetes/reseau/top-sortants.py 2026-10-09
#         python3 /ssd1/kubernetes/reseau/top-sortants.py hier --sauver     # + rapport dans /ssd1/rapports-reseau
# Le rapport automatique (cron, 00:05 pour la veille) s'installe avec installer-cron.sh.
import ipaddress, json, os, re, sys, time, urllib.request
from datetime import date, datetime, timedelta

NTOPNG   = "http://127.0.0.1:3000/lua/rest/v2/"
RRD      = "/ssd1/container/ntopng/data/0/rrd"          # historique ntopng (lu, jamais modifié)
JETON    = "/ssd1/kubernetes/homepage/manuel.env"       # HOMEPAGE_VAR_NTOPNG_TOKEN
DHCP     = "/etc/dhcp/dhcpd.conf"                       # noms des machines (host xxx { ... })
SORTIE   = "/ssd1/rapports-reseau"
GARDER_J = 90                                           # rapports conservés 90 jours
TOP      = 10

# Seuils d'alerte : volume ENVOYÉ par jour, en Mo. Les serveurs envoient beaucoup normalement.
SEUIL_DEFAUT = 2000
SEUILS = {"nas1": 50000, "nas2": 50000, "nas3": 10000}
FACTEUR_INHABITUEL = 5      # alerte aussi si envoi > 5 x la moyenne des 7 derniers jours (et > 100 Mo)

def jeton():
    m = re.search(r"^HOMEPAGE_VAR_NTOPNG_TOKEN=(.+)$", open(JETON).read(), re.M)
    if not m: sys.exit(f"Jeton ntopng introuvable dans {JETON}")
    return m.group(1).strip()

TOK = jeton()
def api(chemin):
    req = urllib.request.Request(NTOPNG + chemin, headers={"Authorization": "Token " + TOK})
    class PasDeRedirection(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k): return None
    try:
        rep = urllib.request.build_opener(PasDeRedirection).open(req, timeout=20)
        return json.load(rep)
    except urllib.error.HTTPError as e:
        if e.code in (301, 302):
            sys.exit("ntopng refuse le jeton (redirection vers la page de connexion) : jeton à recréer, "
                     "puis à mettre dans " + JETON)
        raise

def noms_dhcp():
    par_ip, par_mac = {}, {}
    try:
        for nom, mac, ip in re.findall(r"host\s+(\S+)\s*\{[^}]*?hardware ethernet\s+([0-9A-Fa-f:]+);[^}]*?fixed-address\s+([\d.]+);",
                                       open(DHCP).read()):
            par_ip[ip] = nom; par_mac[mac.upper()] = nom
    except OSError:
        pass
    return par_ip, par_mac

def ips_avec_historique():
    """Adresses locales pour lesquelles ntopng tient un historique (dossier contenant bytes.rrd)."""
    ips = set()
    for dossier, _, fichiers in os.walk(RRD):
        if "bytes.rrd" not in fichiers: continue
        rel = os.path.relpath(dossier, RRD)
        if rel == "." or rel.startswith("hosts"): continue      # historiques par MAC / interface : ignorés
        parts = rel.replace("_", os.sep).split(os.sep)          # IPv6 rangée en 2a01/cb19/02a7/5100/74c3_1c86_..
        for texte in (".".join(parts), ":".join(parts)):
            try:
                ips.add(str(ipaddress.ip_address(texte))); break
            except ValueError:
                pass
    return ips

def volumes(ip, debut, fin):
    r = api(f"get/timeseries/ts.lua?ts_schema=host:traffic&ts_query=ifid:0,host:{ip}"
            f"&epoch_begin={debut}&epoch_end={fin}")
    if r.get("rc") != 0: return 0, 0
    tot = {s.get("id") or s.get("label"): s.get("statistics", {}).get("total", 0) or 0 for s in r["rsp"].get("series", [])}
    return tot.get("bytes_sent", 0), tot.get("bytes_rcvd", 0)

def moyenne_7j(jour):
    """Moyenne des envois par machine sur les 7 jours précédents, d'après les rapports CSV sauvés."""
    cumul, n = {}, 0
    for i in range(1, 8):
        f = os.path.join(SORTIE, (jour - timedelta(days=i)).isoformat() + ".csv")
        if not os.path.exists(f): continue
        n += 1
        for ligne in open(f).read().splitlines()[1:]:
            cle, nom, ips, envoye, recu = ligne.split(";")
            cumul[cle] = cumul.get(cle, 0) + int(envoye)
    return {k: v / n for k, v in cumul.items()} if n else {}, n

def Mo(o): return o / 1e6
def lisible(o): return f"{o/1e9:7.2f} Go" if o >= 1e9 else f"{o/1e6:7.1f} Mo"

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    sauver = "--sauver" in sys.argv
    quand = args[0] if args else "aujourdhui"
    jour = {"aujourdhui": date.today(), "hier": date.today() - timedelta(days=1)}.get(quand) \
           or date.fromisoformat(quand)
    debut = int(datetime.combine(jour, datetime.min.time()).timestamp())
    fin = min(int(time.time()), debut + 86400)

    dhcp_ip, dhcp_mac = noms_dhcp()
    # Machines actives en ce moment : nom et adresse MAC (pour regrouper IPv4 + IPv6 d'un même appareil)
    actifs = {}
    for h in api("get/host/active.lua?ifid=0&mode=local&perPage=5000")["rsp"]["data"]:
        actifs[h["ip"]] = (h.get("mac", "").upper(), h.get("name", ""))

    appareils = {}   # clé (MAC, ou IP si MAC inconnue) -> nom, ips, envoyé, reçu
    for ip in ips_avec_historique():
        envoye, recu = volumes(ip, debut, fin)
        if envoye + recu == 0: continue
        mac, nom_ntop = actifs.get(ip, ("", ""))
        cle = mac or ip
        nom = dhcp_ip.get(ip) or dhcp_mac.get(mac) or (nom_ntop if nom_ntop != ip else "") or "?"
        a = appareils.setdefault(cle, {"nom": nom, "ips": [], "envoye": 0, "recu": 0})
        if a["nom"] == "?": a["nom"] = nom
        a["ips"].append(ip); a["envoye"] += envoye; a["recu"] += recu

    for a in appareils.values():   # IPv4 d'abord, puis IPv6 publique, puis IPv6 locale (fe80::)
        a["ips"].sort(key=lambda i: (":" in i, i.startswith("fe80")))
    moy, n_jours = moyenne_7j(jour)
    JOURS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
    MOIS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
            "octobre", "novembre", "décembre"]
    lignes = [f"TOP {TOP} DES ENVOIS VERS INTERNET — {JOURS[jour.weekday()]} {jour.day} {MOIS[jour.month-1]} {jour.year}"
              f" (de 00:00 à {datetime.fromtimestamp(fin).strftime('%H:%M')})",
              f"Source : ntopng, port miroir de la fibre. Moyenne calculée sur {n_jours} jour(s) de rapports.", "",
              f"{'#':>2}  {'APPAREIL':<18} {'ADRESSE(S)':<28} {'ENVOYÉ':>10} {'REÇU':>10} {'MOY. 7 J':>10}  ALERTE"]
    alertes = []
    classes = sorted(appareils.items(), key=lambda kv: kv[1]["envoye"], reverse=True)
    for rang, (cle, a) in enumerate(classes, 1):
        seuil = SEUILS.get(a["nom"], SEUIL_DEFAUT)
        m = moy.get(cle)
        raisons = []
        if Mo(a["envoye"]) > seuil: raisons.append(f"> {seuil} Mo")
        if m and Mo(a["envoye"]) > 100 and a["envoye"] > FACTEUR_INHABITUEL * m: raisons.append(f"x{a['envoye']/m:.0f} l'habitude")
        if raisons: alertes.append(f"ALERTE {a['nom']} ({', '.join(a['ips'][:2])}) a envoyé {lisible(a['envoye']).strip()} : {', '.join(raisons)}")
        if rang <= TOP:
            ips = a["ips"][0] + (f" +{len(a['ips'])-1}" if len(a["ips"]) > 1 else "")
            lignes.append(f"{rang:>2}  {a['nom'][:18]:<18} {ips[:28]:<28} {lisible(a['envoye'])} {lisible(a['recu'])} "
                          f"{lisible(m) if m else '         -'}  {'⚠ ' + ', '.join(raisons) if raisons else ''}")
    total = sum(a["envoye"] for a in appareils.values())
    lignes += ["", f"Total envoyé par le réseau : {lisible(total).strip()}  ({len(appareils)} appareils actifs)", ""]
    lignes += alertes or ["Aucune alerte."]
    texte = "\n".join(lignes)
    print(texte)

    if sauver:
        os.makedirs(SORTIE, exist_ok=True)
        open(os.path.join(SORTIE, jour.isoformat() + ".txt"), "w").write(texte + "\n")
        with open(os.path.join(SORTIE, jour.isoformat() + ".csv"), "w") as f:
            f.write("cle;nom;ips;envoye;recu\n")
            for cle, a in classes:
                f.write(f"{cle};{a['nom']};{' '.join(a['ips'])};{int(a['envoye'])};{int(a['recu'])}\n")
        limite = time.time() - GARDER_J * 86400
        for f in os.listdir(SORTIE):
            p = os.path.join(SORTIE, f)
            if os.path.getmtime(p) < limite: os.remove(p)
        print(f"\nRapport sauvé dans {SORTIE}/{jour.isoformat()}.txt")

main()
