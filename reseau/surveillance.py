#!/usr/bin/env python3
# SURVEILLANCE DE SÉCURITÉ DU RÉSEAU (lecture seule côté réseau : ne bloque rien, ne modifie pas ntopng).
# Source : ntopng (port miroir de la fibre) -> ne voit que ce qui passe par la box (Internet),
# pas le trafic entre deux appareils de la maison.
#
# Lancé toutes les 5 minutes par cron (installer-cron.sh). À chaque passage :
#   1. lit les connexions en cours dans ntopng et cumule les volumes de la journée
#      (par pays, par site, par appareil -> serveur)
#   2. applique les règles d'alerte (voir REGLES plus bas)
#   3. envoie les NOUVELLES alertes sur l'iPhone (Home Assistant) + notification dans HA
#   4. met à jour les cartes Homepage "Top pays", "Top sites", "Alertes sécurité"
#
# Usage : python3 /ssd1/kubernetes/reseau/surveillance.py               # passage normal (cron)
#         python3 /ssd1/kubernetes/reseau/surveillance.py --resume      # résumé du jour, sans rien envoyer
#         python3 /ssd1/kubernetes/reseau/surveillance.py --test-notif  # envoie une notification de test
#         python3 /ssd1/kubernetes/reseau/surveillance.py --telegram-id # affiche l'identifiant du canal Telegram
# Notifications : Telegram (canal dédié). iPhone + notification Home Assistant seulement si ENVOI_HA = True,
#                 ou en secours quand Telegram échoue.
#
# Règles :
#   EXPORT     un appareil envoie plus de SEUIL_EXPORT_GO vers UN même serveur dans la journée
#   PAYS       un objet connecté parle à un pays à risque (PAYS_RISQUE)
#              (plus d'alerte "pays inédit" depuis le 03/11/2026 : trop de bruit)
#   ENTRANT    une connexion venue d'Internet a abouti sur un appareil de la maison (port ouvert)
#   LISTE NOIRE  échange avec une IP des listes de menaces chargées par ntopng
#   TUNNEL     Tor / VPN / minage / prise en main à distance depuis un appareil non autorisé
#   NTOPNG     alertes de ntopng lui-même (hors fausses alertes connues, voir DNS_CONNUS)
#   NOUVEL APPAREIL  adresse MAC jamais vue sur le réseau (hors réservations de dhcpd.common.conf et
#              interfaces secondaires d'un appareil connu) -> identification du matériel par identifier-pc.py
#   Jamais d'alerte sur le trafic NTP ou DNS (BRUIT), à la demande de l'utilisateur (03/11/2026).
#   VPN / TOR  connexion entrante acceptée depuis Tor, un VPN ou un hébergeur (serveur loué) ;
#              objet connecté qui parle à un nœud Tor ou à un serveur VPN ; tout appareil -> nœud de sortie Tor
#              (listes publiques : projet Tor + X4BNet/lists_vpn, retéléchargées chaque jour)
import bisect, importlib.util, ipaddress, json, os, re, socket, subprocess, sys, time, urllib.parse, urllib.request
from datetime import date, datetime, timedelta

ICI = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("top_sortants", os.path.join(ICI, "top-sortants.py"))
ts = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(ts)   # api(), noms_dhcp(), lisible()

ETAT      = "/var/lib/surveillance-reseau/etat.json"
JETONS    = "/ssd1/kubernetes/homepage/manuel.env"         # HOMEPAGE_VAR_HA_TOKEN (Home Assistant)
HA        = "http://192.168.1.5:8123"
NOTIF_HA  = "mobile_app_iphone_de_sylvain"                 # service notify.* de Home Assistant
ENVOI_HA  = False      # False : Telegram seul (iPhone/HA seulement en secours si Telegram échoue)
OUI       = "/usr/share/ieee-data/oui.txt"                 # fabricants des adresses MAC
TELEGRAM  = os.path.join(ICI, "telegram.env")              # TELEGRAM_BOT_TOKEN=... et TELEGRAM_CHAT_ID=... (hors git)
IDENTIFIER = os.path.join(ICI, "identifier-pc.py")        # identification de chaque nouvel appareil
PREFIXE_V6 = ipaddress.ip_network("2a01:cb19:2a7:5100::/64")
APPRENTISSAGE_J = 7

SEUIL_EXPORT_GO = 1.0
# Serveurs dont les gros envois sont normaux : VPN CyberGhost (datapacket), serveurs de speedtest
EXPORT_NORMAL = re.compile(r"datapacket|ookla|speedtest|liveservices\.fr|cubic|mire\.sfr|lasotel|tailscale", re.I)
PORTS_SPEEDTEST = {8080, 5060}
# Appareils "généralistes" (PC, téléphones, TV...) : ils parlent à tous les pays, pas de règle PAYS inédit
APPAREILS_LIBRES = re.compile(r"nas|laptop|iphone|ipad|redmi|tablette|pc|macbook|android|galaxy|pixel|"
                              r"nintendo|shield|tv|soundbar|box", re.I)
PAYS_RISQUE = {"CN", "RU", "KP", "IR", "BY"}
# Tunnels / outils à surveiller (nom du protocole vu par ntopng)
TUNNEL = re.compile(r"\bTor\b|OpenVPN|WireGuard|Mining|Monero|Stratum|Psiphon|Hotspot|TeamViewer|AnyDesk|RDP", re.I)
TUNNEL_AUTORISE = re.compile(r"^nas\d", re.I)              # gluetun (transmission, jackett) tourne sur les NAS
# Protocoles qui ressemblent à des connexions entrantes mais n'en sont pas (sens mal deviné par ntopng)
ENTRANT_IGNORE = re.compile(r"Tailscale|STUN|ICMP|IPSec|NAT-PMP|SSDP|MDNS|DHCP", re.I)
# Fausses alertes ntopng connues : "Long DNS host name" sur ces domaines, et "Susp. Device Protocol"
DNS_CONNUS = ("a2z.com", "fbcdn.net", "forter.com", "aliyuncs.com", "online-metrix.net", "azure.net",
              "akamaihd.net", "amazonaws.com", "cloudfront.net", "googleapis.com", "")
NTOPNG_IGNORE = {"Susp. Device Protocol"}
# Trafic qui ne déclenche aucune alerte (heure et résolution de noms : bruit sans intérêt)
BRUIT = re.compile(r"\bNTP\b|DNS|DoH|DoT", re.I)

LISTES = "/var/lib/surveillance-reseau/listes"
SOURCES_LISTES = {"tor": "https://check.torproject.org/torbulkexitlist",
                  "vpn": "https://raw.githubusercontent.com/X4BNet/lists_vpn/main/output/vpn/ipv4.txt",
                  "hebergeur": "https://raw.githubusercontent.com/X4BNet/lists_vpn/main/output/datacenter/ipv4.txt"}

PAYS = {"FR": "France", "DE": "Allemagne", "AT": "Autriche", "US": "États-Unis", "GB": "Royaume-Uni",
        "IE": "Irlande", "NL": "Pays-Bas", "BE": "Belgique", "CH": "Suisse", "ES": "Espagne", "IT": "Italie",
        "SE": "Suède", "CA": "Canada", "AU": "Australie", "JP": "Japon", "CN": "Chine", "RU": "Russie",
        "SG": "Singapour", "HK": "Hong Kong", "BR": "Brésil", "IN": "Inde", "PL": "Pologne", "FI": "Finlande",
        "LU": "Luxembourg", "KR": "Corée du Sud", "TW": "Taïwan", "UA": "Ukraine", "IR": "Iran",
        "KP": "Corée du Nord", "BY": "Biélorussie", "NO": "Norvège", "DK": "Danemark", "PT": "Portugal"}

def drapeau(cc):
    return "".join(chr(0x1F1E6 + ord(c) - 65) for c in cc) if len(cc) == 2 and cc.isalpha() else "🌐"
def nom_pays(cc): return f"{drapeau(cc)} {PAYS.get(cc, cc or 'inconnu')}"

def est_local(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return True
    return a.is_private or a.is_link_local or a.is_multicast or a.is_unspecified or \
           (a.version == 6 and a in PREFIXE_V6) or ip.endswith(".255")

_plages = {}
def charger_listes():
    """Listes Tor / VPN / hébergeurs : téléchargées une fois par jour, gardées sur disque
    (si le téléchargement échoue, on garde l'ancienne version)."""
    os.makedirs(LISTES, exist_ok=True)
    for nom, url in SOURCES_LISTES.items():
        f = os.path.join(LISTES, nom + ".txt")
        if not os.path.exists(f) or time.time() - os.path.getmtime(f) > 86400:
            try:
                data = urllib.request.urlopen(url, timeout=30).read()
                if len(data) > 1000:
                    open(f + ".tmp", "wb").write(data); os.replace(f + ".tmp", f)
            except Exception:
                pass
        debuts, fins = [], []
        try:
            plages = sorted((int(n.network_address), int(n.broadcast_address))
                            for n in (ipaddress.ip_network(l.strip(), strict=False)
                                      for l in open(f) if l.strip() and not l.startswith("#")) if n.version == 4)
        except (OSError, ValueError):
            plages = []
        for d, fi in plages: debuts.append(d); fins.append(fi)
        _plages[nom] = (debuts, fins)

def categorie_ip(ip):
    """'Tor', 'VPN', 'hébergeur' ou None (listes IPv4 seulement)."""
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return None
    if a.version != 4: return None
    n = int(a)
    for nom, libelle in (("tor", "Tor"), ("vpn", "VPN"), ("hebergeur", "hébergeur")):
        debuts, fins = _plages.get(nom, ([], []))
        i = bisect.bisect_right(debuts, n) - 1
        if i >= 0 and n <= fins[i]: return libelle
    return None

def charger_etat():
    try:
        return json.load(open(ETAT))
    except (OSError, ValueError):
        return {}

def sauver_etat(e):
    os.makedirs(os.path.dirname(ETAT), exist_ok=True)
    tmp = ETAT + ".tmp"
    json.dump(e, open(tmp, "w"), ensure_ascii=False)
    os.replace(tmp, ETAT)

def fabricant(mac):
    if int(mac[:2], 16) & 2: return "MAC aléatoire (téléphone, tablette ou PC récent)"
    cle = mac[:8].replace(":", "-").upper()
    try:
        for ligne in open(OUI, errors="ignore"):
            if ligne.startswith(cle): return ligne.split("\t")[-1].strip()
    except OSError:
        pass
    return "fabricant inconnu"

# ---------------------------------------------------------------- notifications Home Assistant
def jeton_ha():
    m = re.search(r"^HOMEPAGE_VAR_HA_TOKEN=(.+)$", open(JETONS).read(), re.M)
    return m.group(1).strip() if m else None

def appel_ha(service, donnees):
    req = urllib.request.Request(f"{HA}/api/services/{service}", data=json.dumps(donnees).encode(),
                                 headers={"Authorization": "Bearer " + jeton_ha(), "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=15).read()

def config_telegram():
    try:
        conf = dict(re.findall(r"^(TELEGRAM_\w+)=(.*)$", open(TELEGRAM).read(), re.M))
    except OSError:
        return None, None
    return conf.get("TELEGRAM_BOT_TOKEN", "").strip() or None, conf.get("TELEGRAM_CHAT_ID", "").strip() or None

def telegram(methode, **params):
    jeton, _ = config_telegram()
    req = urllib.request.Request(f"https://api.telegram.org/bot{jeton}/{methode}",
                                 data=urllib.parse.urlencode(params).encode())
    return json.load(urllib.request.urlopen(req, timeout=20))

def notifier(titre, lignes):
    """Envoie partout où c'est configuré ; renvoie le résultat de chaque canal."""
    resultats = []
    jeton, canal = config_telegram()
    if jeton and canal:
        texte = titre + "\n\n" + "\n".join(lignes)
        try:
            for i in range(0, len(texte), 4000):          # limite Telegram : 4096 caractères par message
                telegram("sendMessage", chat_id=canal, text=texte[i:i + 4000], disable_web_page_preview="true")
            resultats.append("Telegram OK")
        except Exception as ex:
            resultats.append(f"Telegram ÉCHEC ({ex})")
    if not ENVOI_HA and resultats == ["Telegram OK"]:
        return "Telegram OK"
    court = [l for l in lignes if not l.startswith("   ")]  # iPhone : une ligne par alerte, sans les détails
    texte = "\n".join(court[:8]) + (f"\n… et {len(court) - 8} autre(s)" if len(court) > 8 else "")
    try:   # HA injoignable : l'alerte reste visible dans Telegram, Homepage et le journal
        appel_ha(f"notify/{NOTIF_HA}", {"title": titre, "message": texte})
        appel_ha("persistent_notification/create", {"title": titre, "message": "\n".join(lignes),
                                                    "notification_id": f"securite_{int(time.time())}"})
        resultats.append("HA OK")
    except Exception as ex:
        resultats.append(f"HA ÉCHEC ({ex})")
    return ", ".join(resultats)

# ---------------------------------------------------------------- adresses (détails des alertes)
def ip_publique_v4(e):
    """IPv4 publique de la box (toutes les machines sortent par elle), relue toutes les 6 h."""
    ip, quand = e.get("ip_publique", ["?", 0])
    if time.time() - quand > 6 * 3600:
        try:
            ip = urllib.request.urlopen("https://api.ipify.org", timeout=5).read().decode().strip()
            e["ip_publique"] = [ip, time.time()]
        except Exception:
            pass
    return ip

def resoudre(ip, nom):
    """IPv4 et IPv6 d'un serveur distant : celle vue + celles de son nom (DNS)."""
    v4, v6 = set(), set()
    (v6 if ":" in ip else v4).add(ip)
    if nom == ip:
        try:
            nom = socket.gethostbyaddr(ip)[0]
        except OSError:
            nom = ""
    if nom:
        try:
            for fam, _, _, _, adr in socket.getaddrinfo(nom, None):
                (v6 if fam == socket.AF_INET6 else v4).add(adr[0])
        except OSError:
            pass
    return sorted(v4)[:2], sorted(v6)[:2], nom

def details(e, hotes, nom_app, ip_moi, distant=None):
    """Lignes de détail d'une alerte : l'appareil (IPv4 locale, IPv6 publique, IPv4 publique de la box)
    et le serveur distant (IPv4 + IPv6)."""
    mac = next((h.get("mac", "").upper() for h in hotes if h["ip"] == ip_moi), "") if ip_moi else ""
    ips = [h["ip"] for h in hotes if mac and h.get("mac", "").upper() == mac] or ([ip_moi] if ip_moi else [])
    v4 = [i for i in ips if ":" not in i]
    v6 = [i for i in ips if ":" in i and not i.startswith("fe80")]
    l = [f"   📱 {nom_app} : IPv4 locale {', '.join(v4) or '-'}" + (f" (MAC {mac})" if mac else ""),
         f"   🌐 vu d'Internet : IPv4 {ip_publique_v4(e)} (box)  |  IPv6 {', '.join(v6[:2]) or '-'}"]
    if distant:
        d4, d6, nom = resoudre(*distant)
        l.append(f"   🎯 distant {nom or distant[1]} : IPv4 {', '.join(d4) or '-'}  |  IPv6 {', '.join(d6) or '-'}")
    return l

def lire_flux():
    """Connexions en cours, page par page : ntopng plante parfois sur une connexion incomplète
    (throughput nil) ; on réessaie la page, puis on la saute plutôt que tout perdre."""
    class PasDeRedirection(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k): return None
    ouvreur = urllib.request.build_opener(PasDeRedirection)
    tout, page = [], 1
    while page < 100:
        lot = None
        for essai in range(3):
            try:
                req = urllib.request.Request(ts.NTOPNG + f"get/flow/active.lua?ifid=0&perPage=1000&currentPage={page}",
                                             headers={"Authorization": "Token " + ts.TOK})
                lot = json.load(ouvreur.open(req, timeout=60))["rsp"]
                break
            except Exception:
                time.sleep(2)
        if lot is None:
            page += 1; continue
        tout += lot["data"]
        if page * 1000 >= int(lot.get("totalRows") or 0): break
        page += 1
    return tout

# ---------------------------------------------------------------- passage principal
def main():
    if "--telegram-id" in sys.argv:
        jeton, _ = config_telegram()
        if not jeton: sys.exit(f"Mets d'abord TELEGRAM_BOT_TOKEN=... dans {TELEGRAM}")
        vus = {}
        for u in telegram("getUpdates").get("result", []):
            m = u.get("channel_post") or u.get("message") or u.get("my_chat_member") or {}
            ch = m.get("chat", {})
            if ch: vus[ch["id"]] = f"{ch.get('type')} « {ch.get('title') or ch.get('username') or ch.get('first_name')} »"
        if not vus: print("Rien reçu : publie un message dans le canal (après y avoir ajouté le bot), puis relance.")
        for i, t in vus.items(): print(f"TELEGRAM_CHAT_ID={i}    <- {t}")
        return
    if "--test-notif" in sys.argv:
        print("Notification de test :", notifier("🛡️ Test surveillance réseau",
                                                 ["Ceci est un test : les alertes réseau arriveront ici."]))
        return
    resume_seul = "--resume" in sys.argv
    maintenant = datetime.now(); aujourdhui = date.today().isoformat()
    e = charger_etat()
    premier_passage = not e
    e.setdefault("debut", aujourdhui)
    e.setdefault("flux", {}); e.setdefault("macs", {}); e.setdefault("pays_appareil", {})
    e.setdefault("deja", {}); e.setdefault("historique", [])
    e.setdefault("ntopng_depuis", int(time.time()) - 300)
    if e.get("jour") != aujourdhui:   # nouvelle journée : remise à zéro des compteurs du jour
        e["jour"] = aujourdhui
        e["j"] = {"pays_out": {}, "pays_in": {}, "sites": {}, "export": {}, "entrants": {}}
        e["deja"] = {k: v for k, v in e["deja"].items() if v == "permanent"}
    j = e["j"]
    apprentissage = date.fromisoformat(e["debut"]) + timedelta(days=APPRENTISSAGE_J) > date.today()

    charger_listes()
    dhcp_ip, dhcp_mac = ts.noms_dhcp()
    hotes = ts.api("get/host/active.lua?ifid=0&mode=local&perPage=5000")["rsp"]["data"]
    mac_de = {h["ip"]: h.get("mac", "").upper() for h in hotes}
    def appareil(ip):
        mac = mac_de.get(ip, "")
        nom = dhcp_ip.get(ip) or dhcp_mac.get(mac) or ip
        return (mac or ip), nom

    nouvelles = []   # (type, texte, lignes de détail)
    a_scanner = []   # nouveaux appareils (mac, nom) à identifier
    def alerte(cle, typ, texte, permanent=False, ip_moi=None, nom_app=None, distant=None):
        if cle in e["deja"]: return
        e["deja"][cle] = "permanent" if permanent else aujourdhui
        try:
            det = details(e, hotes, nom_app or ip_moi or "?", ip_moi, distant) if ip_moi or distant else []
        except Exception as ex:
            det = [f"   (détails indisponibles : {ex})"]
        nouvelles.append((typ, texte, det))

    flux = lire_flux()
    # Connexions déjà ouvertes quand ntopng a démarré : il en devine le sens (souvent faux)
    debut_capture = min((f["first_seen"] for f in flux), default=0)
    vus = {}
    for f in flux:
        c, s = f["client"], f["server"]; l7 = f["protocol"]["l7"]
        cle = f"{f['key']}-{f['first_seen']}"
        local_c, local_s = est_local(c["ip"]), est_local(s["ip"])
        if local_c == local_s: continue                       # local<->local ou distant<->distant
        moi, autre = (c, s) if local_c else (s, c)
        p_cli = f["breakdown"]["cli2srv"] / 100
        envoye = f["bytes"] * (p_cli if local_c else 1 - p_cli); recu = f["bytes"] - envoye
        av_env, av_rec = e["flux"].get(cle, (0, 0))
        d_env = envoye - av_env if envoye >= av_env else envoye
        d_rec = recu - av_rec if recu >= av_rec else recu
        vus[cle] = (envoye, recu)
        cle_app, nom_app = appareil(moi["ip"])
        cc = autre.get("country") or ""
        site = autre.get("name") if autre.get("name") not in (None, "", autre["ip"]) else autre["ip"]

        # cumuls de la journée
        po = j["pays_out"].setdefault(cc, [0, 0, 0]); po[0] += d_env; po[1] += d_rec
        if cle not in e["flux"]: po[2] += 1
        st = j["sites"].setdefault(site, [0, 0, cc]); st[0] += d_env; st[1] += d_rec
        ex = j["export"].setdefault(f"{cle_app}|{autre['ip']}", [0, nom_app, site, cc]); ex[0] += d_env
        if BRUIT.search(l7): continue                         # NTP / DNS : compté, jamais d'alerte

        # EXPORT
        normal = EXPORT_NORMAL.search(site) or (nom_app.startswith("nas") and
                 (autre["port"] in PORTS_SPEEDTEST or categorie_ip(autre["ip"]) == "VPN"))   # CyberGhost, quel que soit le pays
        if ex[0] > SEUIL_EXPORT_GO * 1e9 and not normal:
            alerte(f"export|{cle_app}|{autre['ip']}", "📤 EXPORT",
                   f"{nom_app} a envoyé {ts.lisible(ex[0]).strip()} vers {site} ({nom_pays(cc)}) aujourd'hui",
                   ip_moi=moi["ip"], nom_app=nom_app, distant=(autre["ip"], site))

        # ENTRANT (connexion venue d'Internet qui a abouti)
        if not local_c and f["first_seen"] - debut_capture > 120 and s["port"] < 32768 and c["port"] >= 1024 and not ENTRANT_IGNORE.search(l7) \
           and envoye > 0 and recu > 0 and f["bytes"] > 2000:
            en = j["entrants"].setdefault(f"{s['ip']}:{s['port']}", [0, nom_app, l7, []])
            if cle not in e["flux"]: en[0] += 1
            if cc and cc not in en[3]: en[3].append(cc)
            pi = j["pays_in"].setdefault(cc, [0, 0]); pi[1] += d_env + d_rec
            if cle not in e["flux"]: pi[0] += 1
            cat = categorie_ip(c["ip"])
            alerte(f"entrant|{s['ip']}:{s['port']}", f"🧅 ENTRANT via {cat.upper()}" if cat else "🚪 ENTRANT",
                   f"Connexion depuis Internet ({c['ip']}{', ' + cat if cat else ''}, {nom_pays(cc)}) "
                   f"acceptée par {nom_app} port {s['port']} ({l7})",
                   ip_moi=moi["ip"], nom_app=nom_app, distant=(autre["ip"], site))

        # LISTE NOIRE
        if c.get("is_blacklisted") or s.get("is_blacklisted"):
            alerte(f"noire|{cle_app}|{autre['ip']}", "☠️ LISTE NOIRE",
                   f"{nom_app} échange avec {site} ({nom_pays(cc)}), IP sur liste de menaces ({l7})",
                   ip_moi=moi["ip"], nom_app=nom_app, distant=(autre["ip"], site))

        # TUNNEL / VPN / minage / prise en main à distance
        if TUNNEL.search(l7) and not TUNNEL_AUTORISE.search(nom_app):
            alerte(f"tunnel|{cle_app}|{l7}", "🕳️ TUNNEL", f"{nom_app} utilise {l7} vers {site} ({nom_pays(cc)})",
                   ip_moi=moi["ip"], nom_app=nom_app, distant=(autre["ip"], site))

        # VPN / TOR en sortie : tout appareil -> nœud de sortie Tor ; objet connecté -> Tor ou serveur VPN
        cat = categorie_ip(autre["ip"]) if local_c else None
        objet = not APPAREILS_LIBRES.search(nom_app)
        if cat == "Tor" and not TUNNEL_AUTORISE.search(nom_app) or cat == "VPN" and objet:
            alerte(f"anonyme|{cle_app}|{cat}", "🧅 VPN / TOR",
                   f"{nom_app} parle à un {'nœud de sortie Tor' if cat == 'Tor' else 'serveur VPN'} ({site}, {nom_pays(cc)}, {l7})",
                   ip_moi=moi["ip"], nom_app=nom_app, distant=(autre["ip"], site))

        # PAYS à risque (objets connectés seulement)
        if cc in PAYS_RISQUE and re.fullmatch(r"([0-9A-F]{2}:){5}[0-9A-F]{2}", cle_app) and not APPAREILS_LIBRES.search(nom_app):
            alerte(f"risque|{cle_app}|{cc}", "🌍 PAYS À RISQUE",
                   f"{nom_app} parle à {site} en {nom_pays(cc)} ({l7})", permanent=True,
                   ip_moi=moi["ip"], nom_app=nom_app, distant=(autre["ip"], site))
    e["flux"] = vus

    # NOUVEL APPAREIL
    # Connus = réservations de dhcpd.common.conf seulement (un simple bail DHCP avec un nom ne suffit pas)
    reservees = {m.upper() for m in re.findall(r"hardware ethernet\s+([0-9A-Fa-f:]+);", ts.lire_conf(ts.DHCP))}
    def interface_de(mac):
        """MAC "locale" qui ne diffère d'une MAC réservée que par le 1er et le dernier octet :
        interface secondaire d'un appareil connu (ex. Wi-Fi maillé Deco), pas un nouvel appareil."""
        if not int(mac[:2], 16) & 2: return None
        return next((dhcp_mac.get(m, m) for m in reservees if m != mac and m[3:14] == mac[3:14]), None)
    for h in hotes:
        mac = h.get("mac", "").upper()
        if not mac or mac.startswith(("00:00:00", "FF:FF", "01:00:5E", "33:33")): continue
        if mac not in e["macs"]:
            e["macs"][mac] = aujourdhui
            if premier_passage or mac in reservees or interface_de(mac): continue
            ip4 = next((x["ip"] for x in hotes if x.get("mac", "").upper() == mac and "." in x["ip"]), None)
            nom = h.get("name") if h.get("name") not in (None, "", h["ip"], mac) else dhcp_mac.get(mac, "")
            n = len(nouvelles)
            alerte(f"mac|{mac}", "🆕 NOUVEL APPAREIL",
                   f"{nom + ' ' if nom else ''}{mac} ({fabricant(mac)}) est apparu avec l'IP {ip4 or h['ip']}"
                   " — identification du matériel en cours (rapport dans ~30 min)",
                   permanent=True, ip_moi=ip4 or h["ip"], nom_app=nom or mac)
            if len(nouvelles) > n: a_scanner.append((mac, nom))

    # ALERTES NTOPNG (depuis le dernier passage)
    fin = int(time.time())
    try:
        recs = ts.api(f"get/flow/alert/list.lua?ifid=0&perPage=2000&epoch_begin={e['ntopng_depuis']}&epoch_end={fin}")["rsp"]["records"]
    except Exception:
        recs = []
    for r in recs:
        lab = r["alert_id"]["label"]
        if lab in NTOPNG_IGNORE: continue
        info = r.get("info", {}).get("value", "") if isinstance(r.get("info"), dict) else str(r.get("info") or "")
        if BRUIT.search(f"{lab} {info} {r.get('l7_proto', '')}"): continue      # NTP / DNS : jamais d'alerte
        if lab.startswith("Susp. DNS") and ".".join(info.split(".")[-2:]) in DNS_CONNUS: continue
        cli = r["cli_ip"].get("label", "") if isinstance(r["cli_ip"], dict) else str(r["cli_ip"])
        srv = r["srv_ip"].get("label", "") if isinstance(r["srv_ip"], dict) else str(r["srv_ip"])
        desc = re.sub(r"<[^>]+>", "", r["msg"].get("description", "") if isinstance(r.get("msg"), dict) else "")
        ip_c = r["cli_ip"].get("value", "") if isinstance(r["cli_ip"], dict) else ""
        ip_s = r["srv_ip"].get("value", "") if isinstance(r["srv_ip"], dict) else ""
        moi_ip, autre_ip, autre_nom = (ip_c, ip_s, srv) if est_local(ip_c) else (ip_s, ip_c, cli)
        alerte(f"ntopng|{lab}|{cli}", "🔎 NTOPNG", f"{lab} : {cli} → {srv} {('— ' + desc[:80]) if desc else ''}".strip(),
               ip_moi=moi_ip or None, nom_app=appareil(moi_ip)[1] if moi_ip else None,
               distant=(autre_ip, autre_nom) if autre_ip and not est_local(autre_ip) else None)
    e["ntopng_depuis"] = fin

    # Envoi + historique
    if nouvelles and not resume_seul:
        etat_envoi = notifier(f"🛡️ {len(nouvelles)} alerte(s) réseau",
                              [l for t, x, det in nouvelles for l in [f"{t} {x}"] + det])
    else:
        etat_envoi = "-"
    for t, x, det in nouvelles:
        e["historique"].append({"t": maintenant.strftime("%d/%m %H:%M"), "type": t, "texte": x, "details": det})
    for mac, nom in a_scanner:         # identifier-pc.py (cron chaque minute) l'observe dès qu'il a une IPv4
        if not resume_seul:             # et envoie son propre rapport (marque, type, système, ports)
            subprocess.run([sys.executable, IDENTIFIER, "--ajouter", mac] + ([nom] if nom else []),
                           capture_output=True, timeout=30)
    e["historique"] = e["historique"][-100:]

    sauver_etat(e)                   # d'abord : une alerte déjà notifiée ne doit pas être renvoyée
    try:
        homepage(e, maintenant, apprentissage)
    except Exception as ex:
        print("Homepage : ÉCHEC", ex)

    # Affichage (journal cron / terminal)
    print(f"{maintenant:%d/%m %H:%M} — {len(flux)} connexions lues, {len(nouvelles)} nouvelle(s) alerte(s), "
          f"notification : {etat_envoi}" + (f" — apprentissage jusqu'au "
          f"{date.fromisoformat(e['debut']) + timedelta(days=APPRENTISSAGE_J):%d/%m}" if apprentissage else ""))
    for t, x, det in nouvelles: print("  ", t, x, *["\n" + l for l in det])
    if resume_seul or "-v" in sys.argv:
        print("\nTOP PAYS (aujourd'hui, envoyé / reçu / connexions)")
        for cc, (u, d, n) in sorted(j["pays_out"].items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:10]:
            print(f"  {nom_pays(cc):24} {ts.lisible(u)} {ts.lisible(d)} {n:6}")
        print("\nTOP SITES")
        for site, (u, d, cc) in sorted(j["sites"].items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:10]:
            print(f"  {site[:45]:45} {cc:2} {ts.lisible(u)} {ts.lisible(d)}")
        print("\nCONNEXIONS ENTRANTES ACCEPTÉES :", "aucune" if not j["entrants"] else "")
        for k, (n, nom, l7, pays) in j["entrants"].items():
            print(f"  {nom} ({k}) {l7} : {n} connexion(s) depuis {', '.join(pays) or '?'}")
        print("\nDERNIÈRES ALERTES")
        for h in e["historique"][-10:]:
            print(f"  {h['t']} {h['type']} {h['texte']}", *["\n  " + l for l in h.get("details", [])])

def tailscale():
    """Carte Homepage "Tailscale" : réseau maison partagé, sortie Internet, état de chaque appareil."""
    try:
        st = json.loads(subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=10).stdout)
        prefs = json.loads(subprocess.run(["tailscale", "debug", "prefs"], capture_output=True, text=True, timeout=10).stdout)
    except Exception as ex:
        return [{"nom": "Tailscale", "texte": f"illisible ({ex})"}]
    soi = st["Self"]; pairs = [soi, *st.get("Peer", {}).values()]
    routes = [f"{r} via {p['DNSName'].split('.')[0]}" for p in pairs for r in (p.get("PrimaryRoutes") or [])]
    sortie = next((p["DNSName"].split(".")[0] for p in pairs if p.get("ExitNode")), None)
    lignes = [{"nom": "🏠 Réseau partagé", "texte": ", ".join(routes) or "aucun"},
              {"nom": "🚪 Sortie Internet", "texte": f"par {sortie}" if sortie else "directe (aucun exit node)"}]
    for p in sorted(pairs, key=lambda p: (not p.get("Online"), p["DNSName"])):
        nom = p["DNSName"].split(".")[0]; ip = (p.get("TailscaleIPs") or ["?"])[0]
        if p is soi:
            etat = "ce NAS"
        elif p.get("Online"):
            etat = "direct" if p.get("CurAddr") else f"relais {p.get('Relay') or '?'}"
        else:
            vu = p.get("LastSeen", "")
            try:
                vu = datetime.fromisoformat(vu.replace("Z", "+00:00")).astimezone().strftime("%d/%m %H:%M")
            except ValueError:
                pass
            etat = f"hors ligne, vu le {vu}"
        lignes.append({"nom": f"{'🟢' if p.get('Online') or p is soi else '⚪'} {nom}", "texte": f"{ip} · {etat} · {p.get('OS', '')}"})
    return lignes

def homepage(e, maintenant, apprentissage):
    j = e["j"]
    maj = {"nom": "🕐 Mis à jour", "texte": f"{maintenant:%d/%m à %H:%M}"}
    pays = [maj] + [{"nom": f"{i}. {nom_pays(cc)}", "texte": f"🔺 {ts.lisible(u).strip()}   ↓ {ts.lisible(d).strip()}   · {n} conn."}
                    for i, (cc, (u, d, n)) in enumerate(sorted(j["pays_out"].items(),
                                                               key=lambda kv: -(kv[1][0] + kv[1][1]))[:10], 1)]
    sites = [maj] + [{"nom": f"{i}. {site[:32]}", "texte": f"{drapeau(cc)} 🔺 {ts.lisible(u).strip()}   ↓ {ts.lisible(d).strip()}"}
                     for i, (site, (u, d, cc)) in enumerate(sorted(j["sites"].items(),
                                                                   key=lambda kv: -(kv[1][0] + kv[1][1]))[:10], 1)]
    n_jour = sum(1 for h in e["historique"] if h["t"].startswith(maintenant.strftime("%d/%m")))
    ent = j["entrants"]
    alertes = [{"nom": "🕐 Mis à jour", "texte": f"{maintenant:%H:%M}" + ("  (apprentissage)" if apprentissage else "")},
               {"nom": "Alertes aujourd'hui", "texte": "✅ aucune" if not n_jour else f"⚠️ {n_jour}"},
               {"nom": "Entrants acceptés", "texte": "✅ aucun" if not ent else
                       "⚠️ " + ", ".join(f"{v[1]}:{k.split(':')[-1]}" for k, v in list(ent.items())[:3])}]
    alertes += [{"nom": f"{h['t']} {h['type']}", "texte": h["texte"][:70]} for h in reversed(e["historique"][-8:])]
    donnees = {"pays": pays, "sites": sites, "alertes": alertes, "tailscale": tailscale()}
    cm = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "securite-reseau", "namespace": "media"},
          "data": {"securite-reseau.json": json.dumps(donnees, ensure_ascii=False)}}
    r = subprocess.run(["/usr/local/bin/kubectl", "apply", "-f", "-"], input=json.dumps(cm), text=True, capture_output=True,
                       env={**os.environ, "KUBECONFIG": "/etc/rancher/k3s/k3s.yaml"})
    if r.returncode: print("Homepage : ÉCHEC", r.stderr.strip())

if __name__ == "__main__":
    main()
