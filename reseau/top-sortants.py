#!/usr/bin/env python3
# TOP DES MACHINES QUI ENVOIENT LE PLUS VERS INTERNET (lecture seule, ne modifie rien).
# Source : ntopng (Docker sur nas2), qui écoute le port miroir de la fibre (enp1s0) :
# tout ce qu'il voit passe par la box, donc "envoyé" = upload vers Internet.
#
# Usage : python3 /ssd1/kubernetes/reseau/top-sortants.py                   # aujourd'hui depuis minuit
#         python3 /ssd1/kubernetes/reseau/top-sortants.py hier
#         python3 /ssd1/kubernetes/reseau/top-sortants.py 2026-10-09
#         python3 /ssd1/kubernetes/reseau/top-sortants.py hier --sauver     # + rapport dans /ssd1/rapports-reseau
#         python3 /ssd1/kubernetes/reseau/top-sortants.py --homepage        # + carte "Top envois" de Homepage
# Le rapport automatique (cron, 00:05 pour la veille) s'installe avec installer-cron.sh.
import ipaddress, json, os, re, subprocess, sys, time, urllib.request
from datetime import date, datetime, timedelta

NTOPNG   = "http://127.0.0.1:3000/lua/rest/v2/"
RRD      = "/ssd1/container/ntopng/data/0/rrd"          # historique ntopng (lu, jamais modifié)
JETON    = "/ssd1/kubernetes/homepage/manuel.env"       # HOMEPAGE_VAR_NTOPNG_TOKEN
DHCP     = "/etc/dhcp/dhcpd.conf"                       # noms des machines (host xxx { ... }), + ses "include"
BAUX     = "/var/lib/dhcp/dhcpd.leases"                 # noms des machines en IP dynamique (client-hostname)
NOMS_FIXES = {"192.168.1.1": "box"}                     # appareils absents du DHCP
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
    for essai in range(3):          # ntopng coupe parfois la connexion quand il est occupé
        try:
            rep = urllib.request.build_opener(PasDeRedirection).open(req, timeout=20)
            return json.load(rep)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302):
                sys.exit("ntopng refuse le jeton (redirection vers la page de connexion) : jeton à recréer, "
                         "puis à mettre dans " + JETON)
            raise
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            if essai == 2: raise
            time.sleep(5)

def lire_conf(chemin, vus=None):
    """Texte d'un fichier dhcpd, avec le contenu des fichiers qu'il inclut (include "...";)."""
    vus = vus if vus is not None else set()
    if chemin in vus: return ""
    vus.add(chemin)
    try:
        texte = re.sub(r"#.*", "", open(chemin).read())
    except OSError:
        return ""
    return texte + "".join(lire_conf(f, vus) for f in re.findall(r'include\s+"([^"]+)"\s*;', texte))

def noms_dhcp():
    par_ip, par_mac = dict(NOMS_FIXES), {}
    try:   # baux dynamiques d'abord : les réservations fixes (plus fiables) écrasent ensuite
        for bail in re.findall(r"lease\s+[\d.]+\s*\{[^}]*\}", open(BAUX).read()):
            mac = re.search(r"hardware ethernet\s+([0-9A-Fa-f:]+);", bail)
            nom = re.search(r'client-hostname\s+"([^"]+)";', bail)
            if mac and nom: par_mac[mac.group(1).upper()] = nom.group(1)
    except OSError:
        pass
    for nom, mac, ip in re.findall(r"host\s+(\S+)\s*\{[^}]*?hardware ethernet\s+([0-9A-Fa-f:]+);[^}]*?fixed-address\s+([\d.]+);",
                                   lire_conf(DHCP)):
        par_ip[ip] = nom; par_mac[mac.upper()] = nom
    return par_ip, par_mac

def series_avec_historique():
    """Historiques que ntopng tient (dossiers contenant bytes.rrd) : liste de (requête, ip, mac).
    Rangés par IP (192/168/1/3) jusqu'au 10/10/2026, puis par MAC (hosts/68_1d_ef/36/48/12/v4) car
    ntopng identifie maintenant les machines du réseau local par leur MAC."""
    series = []
    for dossier, _, fichiers in os.walk(RRD):
        if "bytes.rrd" not in fichiers: continue
        rel = os.path.relpath(dossier, RRD)
        if rel == ".": continue
        parts = rel.replace("_", os.sep).split(os.sep)          # IPv6 rangée en 2a01/cb19/02a7/5100/74c3_1c86_..
        if parts[0] == "hosts":                                 # hosts/<mac en 6 morceaux>/v4|v6
            if len(parts) == 8 and parts[7] in ("v4", "v6"):
                mac = ":".join(parts[1:7]).upper()
                series.append((f"{mac}_{parts[7]}", None, mac))
            continue
        for texte in (".".join(parts), ":".join(parts)):
            try:
                ip = str(ipaddress.ip_address(texte)); series.append((ip, ip, None)); break
            except ValueError:
                pass
    return series

def volumes_brut(hote, debut, fin):
    r = api(f"get/timeseries/ts.lua?ts_schema=host:traffic&ts_query=ifid:0,host:{hote}"
            f"&epoch_begin={debut}&epoch_end={fin}")
    if r.get("rc") != 0: return 0, 0
    tot = {s.get("id") or s.get("label"): s.get("statistics", {}).get("total", 0) or 0 for s in r["rsp"].get("series", [])}
    return tot.get("bytes_sent", 0), tot.get("bytes_rcvd", 0)

# FAUX PICS DE NTOPNG. Quand ntopng recrée la fiche d'une adresse IPv6 (adresses temporaires des
# téléphones et PC), il recompte d'un coup tout ce qu'elle a déjà échangé : un point de 5 min de
# plusieurs centaines de Mo, qui revient à l'identique toutes les ~20 min, même téléphone en mode Avion
# (vu le 17/10 : iPhone, +174 Mo envoyés / +585 Mo reçus toutes les 20 min toute la nuit).
# On les reconnaît et on les retire. ntopng ne garde les points à 5 min que 24 h : les heures
# corrigées sont mises en cache pour les rapports faits plus tard.
CACHE      = "/var/lib/top-sortants/heures.json"   # {série: {début d'heure: [envoyé, reçu]}}
PIC_MIN    = 20e6      # un faux pic fait au moins 20 Mo en 5 min
PRECIS_H   = 23        # heures pendant lesquelles ntopng garde les points à 5 min (24, avec une marge)
_cache = None
CORRIGE = {"pics": 0, "octets": 0}

def cache():
    global _cache
    if _cache is None:
        try: _cache = json.load(open(CACHE))
        except (OSError, ValueError): _cache = {}
    return _cache

def sauver_cache():
    if _cache is None: return
    limite = time.time() - 15 * 86400
    for serie in list(_cache):
        _cache[serie] = {h: v for h, v in _cache[serie].items() if int(h) >= limite}
        if not _cache[serie]: del _cache[serie]
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    json.dump(_cache, open(CACHE + ".tmp", "w")); os.replace(CACHE + ".tmp", CACHE)

def points(hote, debut, fin):
    """[(horodatage, octets envoyés, octets reçus)] point par point. Demandé par morceaux de 4 h :
    au-delà, ntopng regroupe les points et les faux pics se noient dans la moyenne."""
    res, t = {}, debut
    while t < fin:
        r = api(f"get/timeseries/ts.lua?ts_schema=host:traffic&ts_query=ifid:0,host:{hote}"
                f"&epoch_begin={t}&epoch_end={min(fin, t + 4 * 3600)}")
        t += 4 * 3600
        if r.get("rc") != 0: continue
        m = r["rsp"]["metadata"]; pas = m["epoch_step"]
        ser = {s.get("id") or s.get("label"): s["data"] for s in r["rsp"].get("series", [])}
        for i, (e, rc) in enumerate(zip(ser.get("bytes_sent", []), ser.get("bytes_rcvd", []))):
            res[m["epoch_begin"] + i * pas] = ((e or 0) * pas, (rc or 0) * pas)
    return sorted((h, e, r) for h, (e, r) in res.items())

def sans_faux_pics(pts):
    """Remplace les faux pics par la moyenne de leurs voisins. Faux pic = point isolé (> 5 fois ses voisins),
    d'au moins PIC_MIN, dont l'envoyé ET le reçu reviennent à 3 % près dans un autre pic à moins de 3 h."""
    tot = [e + r for _, e, r in pts]
    n = len(pts)
    voisins = lambda i: [tot[k] for k in (i - 1, i + 1) if 0 <= k < n]
    pic = [tot[i] > PIC_MIN and tot[i] > 5 * max(voisins(i) or [0]) for i in range(n)]
    proche = lambda a, b: abs(a - b) <= max(0.03 * max(a, b), 1e6)
    res = list(pts)
    for i in range(n):
        if not pic[i]: continue
        if any(pic[j] and j != i and proche(pts[i][1], pts[j][1]) and proche(pts[i][2], pts[j][2])
               for j in range(max(0, i - 36), min(n, i + 37))):
            v = [pts[k] for k in (i - 1, i + 1) if 0 <= k < n]
            res[i] = (pts[i][0], sum(p[1] for p in v) / len(v), sum(p[2] for p in v) / len(v))
            CORRIGE["pics"] += 1; CORRIGE["octets"] += tot[i]
    return res

def volumes(hote, debut, fin):
    """Envoyé et reçu entre debut et fin, sans les faux pics de ntopng."""
    e, r = volumes_brut(hote, debut, fin)
    if e + r < PIC_MIN: return e, r                     # trop peu pour contenir un faux pic
    c = cache().setdefault(hote, {})
    maintenant = int(time.time())
    precis = max(debut, (maintenant - PRECIS_H * 3600) // 3600 * 3600 + 3600)   # 1re heure encore à 5 min
    env = rec = 0
    for h in range(debut, min(precis, fin), 3600):      # heures anciennes : cache, sinon brut (pas mieux)
        v = c.get(str(h)) or volumes_brut(hote, h, min(h + 3600, fin))
        env += v[0]; rec += v[1]
    if precis < fin:
        pts = sans_faux_pics(points(hote, max(precis - 3 * 3600, maintenant - PRECIS_H * 3600), fin))
        heures = {}
        for t, pe, pr in pts:
            if precis < t <= fin:                       # un point couvre les 5 min qui précèdent t
                h = (t - 1) // 3600 * 3600
                v = heures.setdefault(h, [0, 0]); v[0] += pe; v[1] += pr
                env += pe; rec += pr
        for h, v in heures.items():
            if h + 3600 <= maintenant: c[str(h)] = v     # heure finie : gardée pour plus tard
    return env, rec

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

    ips_de_mac = {}
    for ip, (mac, _) in actifs.items():
        if mac: ips_de_mac.setdefault(mac, []).append(ip)

    appareils = {}   # clé (MAC, ou IP si MAC inconnue) -> nom, ips, envoyé, reçu
    for hote, ip, mac in series_avec_historique():
        envoye, recu = volumes(hote, debut, fin)
        if envoye + recu == 0: continue
        ips = [ip] if ip else ips_de_mac.get(mac, [])
        if ip: mac = actifs.get(ip, ("", ""))[0]
        cle = mac or ip
        noms_ntop = [actifs[i][1] for i in ips if i in actifs and actifs[i][1] not in ("", i)]
        nom = next((dhcp_ip[i] for i in ips if i in dhcp_ip), None) or dhcp_mac.get(mac) \
              or (noms_ntop[0] if noms_ntop else "") or "?"
        a = appareils.setdefault(cle, {"nom": nom, "ips": [], "envoye": 0, "recu": 0})
        if a["nom"] == "?": a["nom"] = nom
        a["ips"] += [i for i in ips if i not in a["ips"]]; a["envoye"] += envoye; a["recu"] += recu
    sauver_cache()
    for cle, a in appareils.items():   # MAC sans IP connue (appareil parti) : on affiche la MAC
        if not a["ips"]: a["ips"] = [cle]

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
    lignes += ["", f"Total envoyé par le réseau : {lisible(total).strip()}  ({len(appareils)} appareils actifs)"]
    if CORRIGE["pics"]:
        lignes.append(f"Corrigé : {CORRIGE['pics']} faux pic(s) de ntopng retiré(s) ({lisible(CORRIGE['octets']).strip()} comptés à tort)")
    lignes.append("")
    lignes += alertes or ["Aucune alerte."]
    texte = "\n".join(lignes)
    print(texte)

    if "--homepage" in sys.argv:
        # Données de la carte Homepage : ConfigMap "top-sortants", montée dans le pod Homepage
        # (/app/public/rapports/top-sortants.json) et lue par un widget "customapi".
        # Le widget ne sait pas colorer le texte : on utilise des emoji déjà colorés
        # (🔺 rouge = envoyé vers Internet, ↓ sans couleur = reçu).
        maj = datetime.now()
        top = [{"nom": "🕐 Mis à jour", "texte": f"{JOURS[maj.weekday()][:3]}. {maj:%d/%m} à {maj:%H:%M}"}]
        top += [{"nom": f"{rang}. {a['nom'] if a['nom'] != '?' else a['ips'][0]}",
                 "texte": f"🔺 {lisible(a['envoye']).strip()}   ↓ {lisible(a['recu']).strip()}"
                          + ("  ⚠" if Mo(a["envoye"]) > SEUILS.get(a["nom"], SEUIL_DEFAUT) else "")}
                for rang, (cle, a) in enumerate(classes[:TOP], 1)]
        top.append({"nom": f"Total ({len(appareils)} appareils)",
                    "texte": f"🔺 {lisible(total).strip()}   ↓ {lisible(sum(a['recu'] for a in appareils.values())).strip()}"})
        cm = {"apiVersion": "v1", "kind": "ConfigMap",
              "metadata": {"name": "top-sortants", "namespace": "media"},
              "data": {"top-sortants.json": json.dumps({"jour": jour.isoformat(), "alertes": len(alertes), "top": top},
                                                       ensure_ascii=False)}}
        r = subprocess.run(["/usr/local/bin/kubectl", "apply", "-f", "-"], input=json.dumps(cm), text=True, capture_output=True,
                           env={**os.environ, "KUBECONFIG": "/etc/rancher/k3s/k3s.yaml"})
        print("Homepage :", (r.stdout or r.stderr).strip())

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

if __name__ == "__main__":   # importable par surveillance.py (noms DHCP, API ntopng)
    main()
