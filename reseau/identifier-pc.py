#!/usr/bin/env python3
# IDENTIFIER LE MATÉRIEL D'UN APPAREIL (PC, téléphone, TV, objet connecté...) DÈS QU'IL EST EN LIGNE
# (lecture seule : écoute et questions polies, rien n'est bloqué).
# Tout nouvel appareil détecté par surveillance.py est ajouté ici automatiquement (--ajouter).
# Les appareils ne disent pas leur marque, mais ils contactent les serveurs de leur fabricant
# (HP Support Assistant, iCloud, Alexa, Tuya, Imou...) : on écoute les noms de sites demandés (DNS)
# sur le port miroir enp1s0. En plus : nom et système annoncés en DHCP (Vendor-Class), services et
# modèle annoncés en mDNS (Chromecast, AirPlay, HomeKit, imprimante, « model=iPhone15,2 »...),
# fiche WSD de Windows (fabricant + modèle), et le scan habituel scan-appareil.py sur son IPv4.
# Si la marque n'est pas trouvée, nouvel essai à la prochaine connexion (3 observations au plus).
#
# Usage : python3 /ssd1/kubernetes/reseau/identifier-pc.py --ajouter 38:D5:7A:8B:F0:A1 [nom]   # à surveiller
#         python3 /ssd1/kubernetes/reseau/identifier-pc.py --liste
#         python3 /ssd1/kubernetes/reseau/identifier-pc.py --retirer 38:D5:7A:8B:F0:A1
#         python3 /ssd1/kubernetes/reseau/identifier-pc.py --installer        # cron : vérifie chaque minute
# Le cron lance --verifier ; quand un appareil surveillé apparaît avec une IPv4, il observe 30 min (--observer, en arrière-plan)
# et envoie le résultat sur Telegram. Journal : /var/log/identifier-pc.log
import calendar, importlib.util, json, os, queue, re, socket, subprocess, sys, threading, time, urllib.request, uuid
from datetime import datetime

ICI = os.path.dirname(os.path.abspath(__file__))
LISTE  = "/var/lib/surveillance-reseau/a-identifier.json"
BAUX   = "/var/lib/dhcp/dhcpd.leases"
MIROIR = "enp1s0"
DUREE  = 30 * 60
CRON   = "/etc/cron.d/identifier-pc"
JOURNAL = "/var/log/identifier-pc.log"
MAX_OBSERVATIONS = 3

# Sites des fabricants -> marque. (^|\.) = le nom se termine bien par ce domaine.
MARQUES = [("Lenovo", r"lenovo"), ("HP", r"(^|\.)hp\.com$|hpcloud|hpsmart|hp-ecp|hpconnected|hpeprint"),
           ("Dell", r"(^|\.)dell\.com$|dellcdn|alienware"), ("ASUS", r"(^|\.)asus\.com(\.cn)?$|asuscloud|myasus"),
           ("Acer", r"(^|\.)acer\.com$|acer-group|acercloud|acer-euro"), ("MSI", r"(^|\.)msi\.com$|msi-center"),
           ("Samsung", r"samsung"), ("Huawei", r"huawei|hicloud|dbankcloud"), ("Honor", r"hihonor|(^|\.)honor\.com$"),
           ("Xiaomi", r"xiaomi|(^|\.)mi\.com$|miui"), ("Medion", r"medion"), ("Razer", r"razer"),
           ("Gigabyte", r"gigabyte|aorus"), ("Dynabook / Toshiba", r"dynabook|toshiba"), ("LG", r"(^|\.)lge\.com$|lgecloud"),
           ("Fujitsu", r"fujitsu"), ("Microsoft Surface", r"surface\.microsoft|(^|\.)surface\.com$"),
           # téléphones, tablettes, TV, consoles
           ("Apple", r"captive\.apple\.com|(^|\.)apple\.com$|icloud|mzstatic|apple-dns|aaplimg|push\.apple"),
           ("Oppo / OnePlus / Realme", r"oppo|oneplus|heytap|coloros|realme"), ("Google Nest / Chromecast", r"(^|\.)nest\.com$|chromecast"),
           ("Amazon (Echo / Fire TV / Kindle)", r"device-(messaging|metrics)|dcape-na|fireos|alexa|echocaptiveportal|(^|\.)a2z\.com$|amazondss|kindle"),
           ("Philips TV", r"tpvision|nettvservices|philips-tv"), ("Sony", r"sonyentertainmentnetwork|(^|\.)sony\.(net|com)$"),
           ("PlayStation", r"playstation"), ("Nintendo", r"nintendo"), ("Xbox", r"xboxlive|xbox"), ("Roku", r"roku"),
           ("Sonos", r"sonos"), ("Bose", r"bose"), ("Garmin", r"garmin"), ("Fitbit", r"fitbit"), ("Withings", r"withings"),
           # objets connectés, réseau, imprimantes
           ("Philips Hue", r"meethue"), ("Tuya / Smart Life", r"tuya"), ("Shelly", r"shelly"), ("Sonoff (eWeLink)", r"ewelink|coolkit|itead"),
           ("Imou / Dahua", r"imou|easy4ip|lechange|dahua"), ("Hikvision / Ezviz", r"hikvision|ezviz|hik-connect"),
           ("Reolink", r"reolink"), ("Ring", r"(^|\.)ring\.com$"), ("Netatmo", r"netatmo"), ("Meross", r"meross"),
           ("SwitchBot", r"switchbot"), ("Roborock", r"roborock"), ("Dreame", r"dreame"), ("Ecovacs", r"ecovacs"),
           ("Bosch / Siemens (Home Connect)", r"home-connect|bosch-home"), ("TP-Link / Tapo", r"tplinkcloud|tp-link|tplinknbu|tapo"),
           ("Netgear", r"netgear"), ("Ubiquiti", r"ubnt|ui\.com$"), ("Epson", r"epson"), ("Brother", r"brother"),
           ("Canon", r"canon"), ("Tesla", r"tesla"), ("Zendure", r"zendure"), ("Espressif (ESP32/ESP8266)", r"espressif")]
# Fabricants de puces Wi-Fi/Ethernet : leur nom dans l'adresse MAC ne dit pas la marque de l'appareil
PUCES = re.compile(r"intel|foxconn|hon hai|azurewave|murata|lite-?on|realtek|qualcomm|mediatek|broadcom|universal global|"
                   r"cloud network|ampak|silicon lab|gaoshengda|wistron|pegatron|shenzhen|chongqing|inventec|quectel", re.I)
# Sites qui trahissent le système d'exploitation (test de connexion Internet au démarrage du réseau)
SYSTEMES = [("Windows", r"msftconnecttest|msftncsi|windowsupdate|(^|\.)update\.microsoft\.com$|wns\.windows\.com"),
            ("Android", r"connectivitycheck\.(gstatic|android)|android\.clients\.google|android\.googleapis"),
            ("iOS / macOS", r"captive\.apple\.com"), ("Linux", r"connectivity-check\.ubuntu|(^|\.)ubuntu\.com$|debian\.org|fedoraproject"),
            ("Fire OS (Amazon)", r"fireoscaptiveportal|acsechocaptiveportal")]
# Classe DHCP (option 60) -> système
VENDOR_CLASS = [("Windows", r"^MSFT"), ("Android", r"android"), ("Fire OS (Amazon)", r"amazon"), ("Linux embarqué", r"udhcp|dhcpcd")]
# Services annoncés en mDNS -> type d'appareil
SERVICES_MDNS = [("Chromecast / Google TV / enceinte Google", r"_googlecast"), ("Amazon Fire TV / Echo", r"_amzn-wplay|_amzn-alexa"),
                 ("AirPlay (Apple TV, Mac, TV ou enceinte)", r"_airplay|_raop"), ("accessoire HomeKit", r"_hap\._tcp"),
                 ("imprimante / scanner", r"_ipp|_printer|_pdl-datastream|_scanner|_uscan"),
                 ("enceinte / TV Spotify Connect", r"_spotify-connect"), ("Sonos", r"_sonos"), ("Shelly", r"_shelly"),
                 ("ESPHome", r"_esphomelib"), ("pont Philips Hue", r"_hue\._tcp"), ("appareil Apple", r"_companion-link|_rdlink|_apple-mobdev"),
                 ("NAS / partage de fichiers", r"_smb\._tcp|_afpovertcp")]

def sv():
    spec = importlib.util.spec_from_file_location("sv", os.path.join(ICI, "surveillance.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

def lire():
    try: return json.load(open(LISTE))
    except (OSError, ValueError): return {}

def ecrire(l):
    os.makedirs(os.path.dirname(LISTE), exist_ok=True)
    json.dump(l, open(LISTE + ".tmp", "w"), indent=1, ensure_ascii=False); os.replace(LISTE + ".tmp", LISTE)

def log(*a):
    print(datetime.now().strftime("%d/%m %H:%M:%S"), *a, flush=True)

def bail_actif(mac):
    """(ip, début du bail) si la MAC a un bail DHCP en cours, sinon None."""
    res = None
    for b in re.findall(r"lease\s+([\d.]+)\s*\{([^}]*)\}", open(BAUX).read()):
        if not re.search(r"hardware ethernet\s+" + re.escape(mac.lower()) + ";", b[1].lower()): continue
        debut = re.search(r"starts \d (\S+ \S+);", b[1]); fin = re.search(r"ends \d (\S+ \S+);", b[1])
        if not (debut and fin and "binding state active" in b[1]): continue
        d, f = (calendar.timegm(time.strptime(x.group(1), "%Y/%m/%d %H:%M:%S")) for x in (debut, fin))   # dhcpd écrit en UTC
        if f > time.time(): res = (b[0], d)
    return res

def actif_ntopng(mac):
    """IPv4 de la MAC si ntopng l'a vue dans les 2 dernières minutes."""
    try:
        spec = importlib.util.spec_from_file_location("ts", os.path.join(ICI, "top-sortants.py"))
        ts = importlib.util.module_from_spec(spec); spec.loader.exec_module(ts)
        for h in ts.api("get/host/active.lua?ifid=0&mode=local&perPage=5000")["rsp"]["data"]:
            if h.get("mac", "").upper() == mac and "." in h["ip"] and h.get("last_seen", 0) > time.time() - 120:
                return h["ip"]
    except Exception:
        pass
    return None

def marque_de(nom):
    return next((m for m, motif in MARQUES if re.search(motif, nom, re.I)), None)

def marque_oui(oui):
    """Constructeur de la MAC ramené à une marque connue (« Amazon Technologies Inc. » -> « Amazon (Echo...) »)."""
    return next((m for m, _ in MARQUES if all(w in oui.lower() for w in m.split(" (")[0].lower().split())), oui)

def premier(liste, texte):
    return next((m for m, motif in liste if re.search(motif, texte, re.I)), None)

def infos_bail(mac):
    """Nom et classe DHCP (option 60) du dernier bail de la MAC (l'échange DHCP a eu lieu avant l'écoute)."""
    res = {}
    for b in re.findall(r"lease\s+[\d.]+\s*\{([^}]*)\}", open(BAUX).read()):
        if not re.search(r"hardware ethernet\s+" + re.escape(mac.lower()) + ";", b.lower()): continue
        res = {k: m.group(1) for k, motif in (("nom", r'client-hostname\s+"([^"]+)"'),
                                               ("classe", r'vendor-class-identifier\s*=\s*"([^"]+)"'))
               if (m := re.search(motif, b))}
    return res

def wsd(ip):
    """Fiche WSD de Windows (« Découverte du réseau ») : fabricant, modèle, nom. Vide si le pare-feu refuse."""
    probe = ('<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" '
             'xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
             '<soap:Header><wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>'
             '<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>'
             f'<wsa:MessageID>urn:uuid:{uuid.uuid4()}</wsa:MessageID></soap:Header><soap:Body><wsd:Probe/></soap:Body></soap:Envelope>')
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
        s.sendto(probe.encode(), (ip, 3702)); rep = s.recv(65535).decode(errors="replace")
    except OSError:
        return {}
    adr = re.search(r"<\w*:?Address>(urn:uuid:[^<]+)<", rep); xaddrs = re.search(r"XAddrs>([^<]+)<", rep)
    if not (adr and xaddrs): return {}
    get = ('<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" '
           'xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"><soap:Header>'
           f'<wsa:To>{adr.group(1)}</wsa:To><wsa:Action>http://schemas.xmlsoap.org/ws/2004/09/transfer/Get</wsa:Action>'
           f'<wsa:MessageID>urn:uuid:{uuid.uuid4()}</wsa:MessageID>'
           '<wsa:ReplyTo><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address></wsa:ReplyTo>'
           '</soap:Header><soap:Body/></soap:Envelope>')
    for url in sorted(xaddrs.group(1).split(), key=lambda u: ip not in u):   # l'adresse IPv4 d'abord
        try:
            x = urllib.request.urlopen(urllib.request.Request(url, get.encode(), {"Content-Type": "application/soap+xml"}),
                                       timeout=5).read().decode(errors="replace")
        except OSError:
            continue
        return {k: m.group(1).strip() for k in ("Manufacturer", "ModelName", "ModelNumber", "FriendlyName", "SerialNumber")
                if (m := re.search(rf"<\w*:?{k}[^>]*>([^<]+)<", x))}
    return {}

def observer(mac, ip):
    l = lire(); fiche = l.get(mac, {}); nom = fiche.get("nom") or mac
    log(f"Observation de {nom} ({mac}, {ip}) pendant {DUREE // 60} min")
    tcp = subprocess.Popen(["tcpdump", "-i", MIROIR, "-nn", "-l", "-v", "-s", "1500",
                            f"ether src {mac.lower()} and (udp dst port 53 or udp dst port 5353 or udp dst port 67)"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    scan = subprocess.Popen([sys.executable, os.path.join(ICI, "scan-appareil.py"), ip, mac],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    sv_ = sv()
    noms, indices, hote, envoye = {}, {}, "", False
    systemes, types, modele_mdns = {}, {}, ""
    try: b = infos_bail(mac)
    except OSError: b = {}
    hote = b.get("nom", "")
    oui = sv_.fabricant(mac)                                     # constructeur de la carte réseau
    if not int(mac[:2], 16) & 2 and oui != "fabricant inconnu" and not PUCES.search(oui):
        indices.setdefault(marque_oui(oui), []).append(f"adresse MAC ({oui})")
    if b.get("classe"):
        if (s := premier(VENDOR_CLASS, b["classe"])): systemes.setdefault(s, []).append(f"DHCP « {b['classe']} »")
        if (m := marque_de(b["classe"])): indices.setdefault(m, []).append(f"DHCP « {b['classe']} »")
    lignes_tcp = queue.Queue()
    threading.Thread(target=lambda: [lignes_tcp.put(x) for x in tcp.stdout], daemon=True).start()
    fiche_wsd, essai_wsd, fin = {}, 0, time.time() + DUREE
    while time.time() < fin:
        while not lignes_tcp.empty():
            ligne = lignes_tcp.get()
            for n in re.findall(r"(?:A|AAAA|HTTPS|SRV|PTR|TXT|CNAME)\? ([\w.-]+?)\.? ", ligne):
                if n.lower().endswith(".local"): continue        # questions mDNS : il cherche les autres, ce n'est pas lui
                noms[n.lower()] = noms.get(n.lower(), 0) + 1
                if (m := marque_de(n)): indices.setdefault(m, []).append(n.lower())
                if (s := premier(SYSTEMES, n)): systemes.setdefault(s, []).append(n.lower())
            if (h := re.search(r'Hostname[^"]*"([^"]+)"', ligne)): hote = h.group(1)
            if (v := re.search(r'Vendor-Class[^"]*"([^"]+)"', ligne)):
                if (s := premier(VENDOR_CLASS, v.group(1))): systemes.setdefault(s, []).append(f"DHCP « {v.group(1)} »")
            if "?" not in ligne and ".local" in ligne:          # annonce mDNS de l'appareil lui-même
                for t, motif in SERVICES_MDNS:
                    if re.search(motif, ligne): types.setdefault(t, 1)
                for n in set(re.findall(r"([\w-]+)\.local", ligne)):     # son nom mDNS (ex. shellyem-EC64C9C69412)
                    if not n.startswith("_") and (m := marque_de(n)): indices.setdefault(m, []).append(f"mDNS {n}")
                if (md := re.search(r'model=([^"\s,]+(?:,\d+)?)', ligne)):
                    modele_mdns = md.group(1)
                    if re.match(r"(iPhone|iPad|Mac|AppleTV|Watch|AudioAccessory|iMac)", modele_mdns):
                        indices.setdefault("Apple", []).append(f"mDNS model={modele_mdns}")
        if not fiche_wsd and time.time() > essai_wsd:            # le PC n'ouvre WSD qu'une fois Windows démarré
            fiche_wsd = wsd(ip); essai_wsd = time.time() + 120
            if fiche_wsd:
                log("WSD :", fiche_wsd)
                fab = fiche_wsd.get("Manufacturer", "")
                m = marque_de(fab + " " + fiche_wsd.get("ModelName", "")) or ("" if re.search("microsoft", fab, re.I) else fab)
                if m: indices.setdefault(m, []).append("fiche WSD de Windows")
        if not envoye and any(not p.startswith("adresse MAC") for v in indices.values() for p in v):
            m, preuves = max(indices.items(), key=lambda kv: len(kv[1]))      # (la MAC seule ne suffit pas pour ce message)
            modele = f" {fiche_wsd.get('ModelName', '') or modele_mdns}".rstrip()
            log("Marque trouvée :", m, preuves[:5])
            log("Notification :", sv_.notifier(f"🆔 {nom} identifié : {m}{modele}",
                                                [f"   Indice : {', '.join(dict.fromkeys(preuves))[:300]}",
                                                 f"   IP {ip}, MAC {mac}" + (f", nom annoncé {hote}" if hote else ""),
                                                 "   Rapport complet dans 30 min."]))
            envoye = True
        time.sleep(5)
    tcp.terminate()
    try: rapport_scan = scan.communicate(timeout=300)[0]
    except subprocess.TimeoutExpired: scan.kill(); rapport_scan = ""
    lignes_scan = [x for x in rapport_scan.splitlines() if re.match(r"\s+(🏭|🏷️|🧩|💻|🚪)", x)]
    top = sorted(noms.items(), key=lambda kv: -kv[1])[:12]
    marque = max(indices.items(), key=lambda kv: len(kv[1]))[0] if indices else None
    systeme = max(systemes.items(), key=lambda kv: len(kv[1]))[0] if systemes else None
    lignes = [f"   Marque : {marque or 'pas trouvée cette fois'}"
              + (f" — {fiche_wsd.get('Manufacturer', '')} {fiche_wsd.get('ModelName', '')} {fiche_wsd.get('ModelNumber', '')}".rstrip()
                 if fiche_wsd else "") + (f" — modèle {modele_mdns}" if modele_mdns else ""),
              f"   Système : {systeme or 'non trouvé'}" + (f" ({', '.join(dict.fromkeys(systemes[systeme]))[:120]})" if systeme else ""),
              f"   Type (services annoncés) : {', '.join(types) or 'aucun service annoncé'}",
              f"   Nom annoncé (DHCP) : {hote or fiche_wsd.get('FriendlyName', '') or 'aucun'}",
              *lignes_scan,
              f"   Sites les plus demandés : {', '.join(n for n, _ in top) or 'aucun'}"]
    obs = lire().get(mac, {}).get("observations", 0) + 1
    if not marque:
        lignes.append("   Je réessaierai à sa prochaine connexion." if obs < MAX_OBSERVATIONS
                      else f"   Abandon après {obs} observations.")
    log("\n".join(lignes))
    log("Notification :", sv_.notifier(f"🆔 Rapport sur {nom}" + (f" ({mac})" if nom != mac else ""), lignes))
    l = lire()
    if mac in l:
        l[mac]["observations"] = l[mac].get("observations", 0) + 1
        l[mac]["derniere"] = time.time()
        if marque:
            l[mac].update(marque=marque, modele=fiche_wsd.get("ModelName", "") or modele_mdns, fini=True)
        if systeme: l[mac]["systeme"] = systeme
        if l[mac]["observations"] >= MAX_OBSERVATIONS: l[mac]["fini"] = True
        if hote: l[mac]["hote"] = hote
        ecrire(l)

def verifier():
    l = lire()
    for mac, f in l.items():
        if f.get("fini"): continue
        en_cours = f.get("pid") and os.path.exists(f"/proc/{f['pid']}")
        if en_cours: continue
        b = bail_actif(mac)
        if b:
            ip, debut = b                                   # nouveau bail = le PC vient de démarrer
        else:                                               # réservation DHCP (pas de bail) : vu par ntopng ?
            ip = actif_ntopng(mac)                          # (appareils qui n'ont qu'une IPv6 : on attend)
            if not ip: continue
            debut = time.time() if time.time() - f.get("derniere_detection", 0) > 2 * 3600 else 0
        if debut <= f.get("derniere_detection", 0): continue
        log(f"{f.get('nom') or mac} est allumé ({ip}) : lancement de l'observation")
        p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--observer", mac, ip],
                             stdout=open(JOURNAL, "a"), stderr=subprocess.STDOUT, start_new_session=True)
        f.update(pid=p.pid, derniere_detection=time.time())
        ecrire(l)

def main():
    a = sys.argv[1:]
    if a[:1] == ["--ajouter"]:
        mac = a[1].upper(); l = lire()
        if mac in l and not a[2:]: print(f"{mac} déjà dans la liste."); return
        l[mac] = {"nom": " ".join(a[2:]) or l.get(mac, {}).get("nom") or "Nouvel appareil", "ajoute": datetime.now().isoformat(timespec="minutes")}
        ecrire(l); print(f"{mac} ajouté : il sera observé dès qu'il sera en ligne avec une IPv4.")
    elif a[:1] == ["--retirer"]:
        l = lire(); l.pop(a[1].upper(), None); ecrire(l); print("Retiré.")
    elif a[:1] == ["--liste"]:
        for mac, f in lire().items():
            print(f"{mac}  {f.get('nom')}  " + (f"→ {f.get('marque', 'non identifié')} {f.get('modele', '')}".rstrip()
                                                 + (f" (nom d'ordinateur « {f['hote']} »)" if f.get("hote") else "") if f.get("fini")
                                                 else f"en attente ({f.get('observations', 0)} observation(s))"))
    elif a[:1] == ["--observer"]:
        observer(a[1].upper(), a[2])
    elif a[:1] == ["--installer"]:
        open(CRON, "w").write("# Identification des appareils surveillés (voir /ssd1/kubernetes/reseau/identifier-pc.py)\n"
                              f"* * * * * root /usr/bin/python3 {os.path.abspath(__file__)} --verifier >> {JOURNAL} 2>&1\n")
        os.chmod(CRON, 0o644); print("Installé :", CRON)
    elif a[:1] == ["--verifier"]:
        verifier()
    else:
        sys.exit(open(__file__).read().split("import ")[0])

if __name__ == "__main__":
    main()
