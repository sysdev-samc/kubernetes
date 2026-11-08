#!/usr/bin/env python3
# SCAN D'UN APPAREIL DU RÉSEAU LOCAL : rassemble un maximum d'informations pour l'identifier.
# Lancé automatiquement par surveillance.py pour chaque NOUVEL APPAREIL ; utilisable à la main.
#
# Sources : fabricant (adresse MAC), bail DHCP (nom, système annoncé), ntopng (nom mDNS/DHCP,
#           type et système estimés, applications utilisées), nmap (1000 ports TCP les plus courants
#           + UDP 137/161/1900/5353, versions des services, système, NetBIOS, UPnP, mDNS, titre web, certificat).
# Durée : 1 à 5 minutes. Ne fait que regarder (aucune tentative de connexion avec mot de passe).
#
# Usage : python3 /ssd1/kubernetes/reseau/scan-appareil.py 192.168.1.231              # affiche le rapport
#         python3 /ssd1/kubernetes/reseau/scan-appareil.py 192.168.1.231 --notifier   # + Telegram / iPhone
# Rapports : /var/lib/surveillance-reseau/scans/AAAA-MM-JJ_HHMM_<ip>.txt
import importlib.util, ipaddress, os, re, subprocess, sys, tempfile, xml.etree.ElementTree as ET
from datetime import datetime

ICI = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("surveillance", os.path.join(ICI, "surveillance.py"))
sv = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(sv)
ts = sv.ts

RAPPORTS = "/var/lib/surveillance-reseau/scans"
BAUX     = "/var/lib/dhcp/dhcpd.leases"
SERVICES = "/usr/share/nmap/nmap-services"
NB_PORTS = 1000
UDP      = "137,161,1900,5353"            # NetBIOS, SNMP, UPnP, mDNS : très parlants pour identifier
SCRIPTS  = "nbstat,http-title,http-server-header,ssl-cert,upnp-info,dns-service-discovery,snmp-sysdescr"

TYPES_NTOPNG = {1: "imprimante", 2: "caméra / vidéo", 3: "ordinateur fixe", 4: "ordinateur portable",
                5: "tablette", 6: "téléphone", 7: "TV", 8: "équipement réseau", 9: "point d'accès Wi-Fi",
                10: "NAS", 11: "multimédia", 12: "objet connecté"}
OS_NTOPNG = {1: "Linux", 2: "Windows", 3: "macOS", 4: "iOS", 5: "Android"}
# Indices -> type probable (cherchés dans tout ce qu'on a appris)
INDICES = [(r"printer|imprim|ipp|jetdirect|epson|brother|canon|hp ", "imprimante"),
           (r"camera|rtsp|onvif|imou|dahua|hikvision|ezviz|reolink|tapo c", "caméra"),
           (r"roku|chromecast|googlecast|airplay|dlna|webos|tizen|bravia|smart ?tv|fire ?tv|shield", "TV / box multimédia"),
           (r"echo|alexa|amazon", "appareil Amazon (Echo / Fire TV)"),
           (r"sonos|soundbar|speaker|bose", "enceinte"),
           (r"iphone|ipad|ios", "iPhone / iPad"), (r"android|galaxy|redmi|xiaomi|pixel", "téléphone Android"),
           (r"windows|microsoft-ds|netbios|msrpc", "PC Windows"), (r"macos|mac os|apple", "appareil Apple"),
           (r"shelly|sonoff|tasmota|esphome|espressif|tuya|tp-link smart|hs110|switchbot|zigbee|mqtt",
            "objet connecté (prise, relais, capteur)"),
           (r"synology|qnap|nas|samba", "NAS"), (r"router|routeur|switch|access point|deco|ubiquiti|mikrotik", "équipement réseau"),
           (r"playstation|xbox|nintendo", "console de jeu"), (r"linux", "appareil Linux")]

def ports_courants(n):
    """Les n ports TCP les plus utilisés sur Internet (fréquences de nmap)."""
    lst = []
    for ligne in open(SERVICES):
        p = ligne.split()
        if len(p) >= 3 and p[1].endswith("/tcp") and not ligne.startswith("#"):
            lst.append((float(p[2]), int(p[1].split("/")[0])))
    return sorted({port for _, port in sorted(lst, reverse=True)[:n]})

def bail(mac):
    """Dernier bail DHCP de cette MAC : nom annoncé et identifiant du système (vendor-class)."""
    res = {}
    try:
        for b in re.findall(r"lease\s+[\d.]+\s*\{[^}]*\}", open(BAUX).read()):
            if mac and re.search(r"hardware ethernet\s+" + re.escape(mac.lower()) + ";", b.lower()):
                if res and "binding state active" not in b: continue     # un bail actif l'emporte sur un vieux bail
                res = {}
                for cle, motif in (("nom", r'client-hostname\s+"([^"]+)"'),
                                   ("systeme", r'vendor-class-identifier\s*=\s*"([^"]+)"')):
                    m = re.search(motif, b)
                    if m: res[cle] = m.group(1)
    except OSError:
        pass
    return res

def ntopng(ip):
    try:
        d = ts.api(f"get/host/data.lua?ifid=0&host={ip}")["rsp"]
    except BaseException:          # ts.api fait sys.exit si le jeton est refusé
        return {}
    apps = sorted(((v.get("bytes.sent", 0) + v.get("bytes.rcvd", 0), k) for k, v in (d.get("ndpi") or {}).items()
                   if isinstance(v, dict)), reverse=True)
    return {"noms": d.get("names") or {}, "type": TYPES_NTOPNG.get(d.get("devtype")), "os": OS_NTOPNG.get(d.get("os")),
            "os_detail": d.get("os_detail") or "", "apps": [k for _, k in apps[:6]], "mac": (d.get("mac") or "").upper()}

def nmap(ip):
    ports = ",".join(map(str, ports_courants(NB_PORTS)))
    with tempfile.NamedTemporaryFile(suffix=".xml", delete=False) as t: xml = t.name
    subprocess.run(["nmap", "-n", "-Pn", "-T3", "--max-rate", "150", "--max-retries", "3", "-sS", "-sU", "-p", f"T:{ports},U:{UDP}", "-sV", "--version-light",
                    "-O", "--osscan-guess", "--script", SCRIPTS, "--host-timeout", "300s", "-oX", xml, ip],
                   capture_output=True, text=True, timeout=420)
    res = {"ports": [], "os": [], "scripts": {}, "mac_vendor": "", "devicetype": set()}
    try:
        h = ET.parse(xml).getroot().find("host")
    finally:
        os.unlink(xml)
    if h is None: return res
    for a in h.findall("address"):
        if a.get("addrtype") == "mac": res["mac_vendor"] = a.get("vendor", "")
    for p in h.findall("ports/port"):
        st = p.find("state").get("state")
        if st not in ("open",): continue
        sv_ = p.find("service")
        desc = ""
        if sv_ is not None:
            desc = " ".join(x for x in (sv_.get("name"), sv_.get("product"), sv_.get("version"), sv_.get("extrainfo")) if x)
            if sv_.get("devicetype"): res["devicetype"].add(sv_.get("devicetype"))
        res["ports"].append(f"{p.get('portid')}/{p.get('protocol')} {desc}".strip())
        for sc in p.findall("script"):
            res["scripts"][f"{sc.get('id')} ({p.get('portid')})"] = " ".join(sc.get("output", "").split())[:200]
    for sc in h.findall("hostscript/script"):
        res["scripts"][sc.get("id")] = " ".join(sc.get("output", "").split())[:200]
    for m in h.findall("os/osmatch")[:3]:
        cls = m.find("osclass")
        typ = f", {cls.get('type')}" if cls is not None and cls.get("type") else ""
        res["os"].append(f"{m.get('name')} ({m.get('accuracy')} %{typ})")
        if cls is not None and cls.get("type"): res["devicetype"].add(cls.get("type"))
    return res

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args: sys.exit(__doc__ or "usage : scan-appareil.py <ip> [mac] [--notifier]")
    ip = args[0]; ipaddress.ip_address(ip)
    nt = ntopng(ip)
    mac = (args[1] if len(args) > 1 else nt.get("mac", "")).upper()
    debut = datetime.now()
    nm = nmap(ip)
    dh = bail(mac)
    dhcp_ip, dhcp_mac = ts.noms_dhcp()

    fab = nm["mac_vendor"] or (sv.fabricant(mac) if mac else "inconnu")
    if mac and int(mac[:2], 16) & 2: fab += " — MAC aléatoire (téléphone, tablette ou PC récent : fabricant masqué)"
    noms = [n for n in [dhcp_ip.get(ip), dhcp_mac.get(mac), dh.get("nom"), *nt.get("noms", {}).values()] if n]
    # Indices fiables d'abord (noms, constructeur, DHCP, nmap) ; les applications utilisées ne servent
    # qu'en dernier recours (un PC qui utilise AmazonAWS n'est pas un Echo). Les estimations de ntopng
    # (type, système) se trompent souvent : affichées pour info, jamais utilisées pour deviner.
    fiable = " ".join([fab, *noms, dh.get("systeme", ""), *nm["ports"], *nm["os"], *nm["scripts"].values(),
                       *nm["devicetype"]]).lower()
    probables = [t for motif, t in INDICES if re.search(motif, fiable)] or \
                [t + " (d'après ses applications)" for motif, t in INDICES if re.search(motif, " ".join(nt.get("apps", [])).lower())]

    l = [f"🔍 Scan de {ip}" + (f" ({noms[0]})" if noms else "") + f" — {debut:%d/%m %H:%M}",
         f"   🏭 Constructeur : {fab}" + (f"  (MAC {mac})" if mac else ""),
         f"   🏷️ Nom(s) annoncé(s) : {', '.join(dict.fromkeys(noms)) or 'aucun'}",
         f"   🧩 Type probable : {', '.join(dict.fromkeys(probables[:3])) or 'indéterminé'}"
         + (f"  (estimation ntopng, peu fiable : {nt['type']})" if nt.get("type") else ""),
         f"   💻 Système : " + (" ; ".join(x for x in [dh.get("systeme") and f"DHCP « {dh['systeme']} »",
                                                     nt.get("os") and f"ntopng (peu fiable) {nt['os']} {nt.get('os_detail', '')}".strip(),
                                                     nm["os"] and f"nmap {nm['os'][0]}"] if x) or "inconnu"),
         f"   🚪 Ports ouverts : " + (", ".join(nm["ports"][:12]) if nm["ports"] else "aucun (tout est fermé ou filtré)"),
         f"   📡 Applications vues par ntopng : {', '.join(nt.get('apps', [])) or '-'}"]
    for k, v in nm["scripts"].items():
        l.append(f"   📝 {k} : {v}")

    os.makedirs(RAPPORTS, exist_ok=True)
    f = os.path.join(RAPPORTS, f"{debut:%Y-%m-%d_%H%M}_{ip.replace(':', '_')}.txt")
    open(f, "w").write("\n".join(l) + "\n")
    print("\n".join(l)); print(f"\nRapport : {f}")
    if "--notifier" in sys.argv:
        print("Notification :", sv.notifier(f"🔍 Nouvel appareil {ip} identifié", l[1:] + [f"   Rapport : {f}"]))

if __name__ == "__main__":
    main()
