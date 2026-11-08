#!/usr/bin/env python3
# ÉTAT DES DISQUES DE TOUS LES NAS -> carte "Disques" de Homepage (+ résumé Telegram).
# Lit la liste des disques dans disques/smartd.<nas>.conf (même source que smartd), interroge
# chacun avec "smartctl -j" (en local ou par SSH), classe son état (✅ 🟠 🔴) et publie le tout
# dans le ConfigMap "disques" (monté dans Homepage : http://localhost:3000/rapports/disques.json).
# Les ALERTES immédiates restent le travail de smartd (smartd-alerte.sh) ; ici : vue d'ensemble.
#
# Usage (sur nas2, en root) :
#   python3 /ssd1/kubernetes/disques/disques.py               # affiche l'état
#   python3 /ssd1/kubernetes/disques/disques.py --homepage    # + met à jour la carte Homepage
#   python3 /ssd1/kubernetes/disques/disques.py --telegram    # + envoie le résumé sur Telegram
# Planifié par disques/installer-cron.sh (Homepage chaque heure, Telegram le lundi à 11 h 05).
import importlib.util, json, os, re, socket, subprocess, sys
from datetime import datetime

ICI = os.path.dirname(os.path.abspath(__file__))
NOEUDS = ["nas1", "nas2", "nas3"]
ENV = {**os.environ, "KUBECONFIG": "/etc/rancher/k3s/k3s.yaml",
       "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}   # cron n'a pas /usr/local/bin
# Noms courts affichés (début du by-id -> nom lisible)
NOMS = {"ata-ST4000VN008": "IronWolf 4 To (/volume1)", "ata-Samsung_SSD_860_PRO_1TB_S42NNF0KA": "SSD système 1 To",
        "ata-Samsung_SSD_860_PRO_1TB_S42NNF0K9": "SSD 1 To (/volume1)", "ata-CYX-SSD": "SSD système 256 Go",
        "nvme-CT250P2SSD8": "NVMe 250 Go (etcd, Longhorn)"}
# Seuils de température (°C) : attention / critique — les mêmes que -W dans smartd.<nas>.conf
TEMP = {"hdd": (45, 55), "ssd": (60, 70), "nvme": (70, 80)}

def sur(noeud, cmd):
    """Lance une commande sur un nœud (en local si c'est cette machine). Renvoie stdout ou None."""
    if noeud == socket.gethostname().split(".")[0]:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, env=ENV, timeout=60)
    else:
        r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", noeud, cmd],
                           capture_output=True, text=True, timeout=90)
    return r.stdout if r.stdout else None

def disques_du(noeud):
    """[(chemin by-id, type -d)] lus dans le smartd.<nœud>.conf du dépôt."""
    res = []
    for ligne in open(os.path.join(ICI, f"smartd.{noeud}.conf")):
        if ligne.startswith("/dev/"):
            m = re.search(r"-d (\S+)", ligne)
            res.append((ligne.split()[0], m.group(1) if m else "auto"))
    return res

def nom_court(chemin):
    base = os.path.basename(chemin)
    return next((v for k, v in NOMS.items() if base.startswith(k)), base[:28])

def etat(noeud, chemin, typ):
    """Analyse d'un disque -> dict (niveau 0 ✅ / 1 🟠 / 2 🔴, texte, détails)."""
    sortie = sur(noeud, f"smartctl -j -a -d {typ} {chemin}")
    nom = f"{noeud} · {nom_court(chemin)}"
    if not sortie:
        return {"nom": nom, "niveau": 2, "texte": "🔴 injoignable (nœud éteint ou disque absent)"}
    d = json.loads(sortie)
    pb, att = [], []                                                # problèmes graves / points d'attention
    if d.get("smart_status", {}).get("passed") is False:
        pb.append("SMART FAILED")
    attrs = {a["id"]: a for a in d.get("ata_smart_attributes", {}).get("table", [])}
    raw = lambda i: attrs[i]["raw"]["value"] if i in attrs else None
    nvme = d.get("nvme_smart_health_information_log")
    rotation = d.get("rotation_rate", 0)
    genre = "nvme" if nvme else ("hdd" if rotation else "ssd")

    if raw(197): pb.append(f"{raw(197)} en attente")
    if raw(198): pb.append(f"{raw(198)} illisibles")
    if raw(5):   att.append(f"{raw(5)} réalloués")
    if genre == "hdd" and raw(187): att.append(f"{raw(187)} erreurs")
    if genre == "hdd" and (raw(193) or 0) > 300000: att.append(f"{raw(193) // 1000}k parkings")
    usure = None
    if nvme:
        usure = nvme.get("percentage_used")
        if nvme.get("critical_warning"): pb.append(f"alerte NVMe {nvme['critical_warning']}")
        if nvme.get("media_errors"):     pb.append(f"{nvme['media_errors']} erreurs média")
    else:
        for i in (177, 233, 231, 202):                               # usure SSD (valeur normalisée : 100 = neuf)
            if i in attrs and genre == "ssd":
                usure = 100 - attrs[i]["value"]; break
    if usure is not None and usure >= 80: (pb if usure >= 90 else att).append(f"usure {usure} %")

    t = d.get("temperature", {}).get("current")
    if t is not None and t >= TEMP[genre][0]: (pb if t >= TEMP[genre][1] else att).append(f"{t} °C")

    # Dernier autotest (ATA) ou autotest en cours
    test = ""
    en_cours = d.get("ata_smart_data", {}).get("self_test", {}).get("status", {})
    journal = d.get("ata_smart_self_test_log", {}).get("standard", {}).get("table", [])
    if en_cours.get("remaining_percent"):
        test = f"test en cours ({100 - en_cours['remaining_percent']} %)"
    elif journal:
        dernier = journal[0]
        if dernier.get("status", {}).get("passed") is False:
            pb.append(f"autotest {dernier.get('type', {}).get('string', '').split()[0].lower()} ÉCHOUÉ")
        else:
            test = "dernier test OK"

    niveau = 2 if pb else (1 if att else 0)
    resume = [x for x in (f"usure {usure} %" if usure is not None and genre != "hdd" else "",
                          f"{t} °C" if t is not None else "", test) if x]
    if niveau == 0:
        texte = "✅ " + " · ".join(resume)
    else:
        texte = ("🔴 " if niveau == 2 else "🟠 ") + " · ".join(pb + att)
    heures = d.get("power_on_time", {}).get("hours")
    return {"nom": nom, "niveau": niveau, "texte": texte[:80],
            "details": " · ".join(resume + ([f"{heures // 8760} ans {heures % 8760 // 730} mois de marche"] if heures else []))}

def emmc_nas3():
    """L'eMMC de nas3 n'a pas de SMART : on compte ses erreurs dans le journal du noyau (7 jours)."""
    n = sur("nas3", "journalctl -k --since -7d --no-pager 2>/dev/null | grep -ciE 'mmcblk.*(error|timeout|fail)'")
    if n is None:
        return {"nom": "nas3 · eMMC système", "niveau": 2, "texte": "🔴 nas3 injoignable"}
    n = int(n.strip() or 0)
    return {"nom": "nas3 · eMMC système", "niveau": 1 if n else 0,
            "texte": f"🟠 {n} erreur(s) noyau sur 7 j" if n else "✅ aucune erreur noyau (7 j)"}

def main():
    lignes = []
    for noeud in NOEUDS:
        for chemin, typ in disques_du(noeud):
            try:
                lignes.append(etat(noeud, chemin, typ))
            except Exception as ex:
                lignes.append({"nom": f"{noeud} · {nom_court(chemin)}", "niveau": 2, "texte": f"🔴 lecture impossible ({ex})"[:80]})
    lignes.append(emmc_nas3())
    lignes.sort(key=lambda l: -l["niveau"])                         # les problèmes en premier
    maj = datetime.now()
    bilan = {0: "✅ tous les disques vont bien", 1: "🟠 point(s) d'attention", 2: "🔴 disque(s) à problème"}[max(l["niveau"] for l in lignes)]

    for l in lignes:
        print(f"{l['nom']:45} {l['texte']}")

    if "--homepage" in sys.argv:
        carte = [{"nom": "🕐 Mis à jour", "texte": f"{maj:%d/%m à %H:%M} · {bilan}"}] + \
                [{"nom": l["nom"], "texte": l["texte"]} for l in lignes]
        cm = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "disques", "namespace": "media"},
              "data": {"disques.json": json.dumps({"disques": carte}, ensure_ascii=False)}}
        r = subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(cm), text=True, capture_output=True, env=ENV)
        print("Homepage :", (r.stdout or r.stderr).strip())

    if "--telegram" in sys.argv:
        spec = importlib.util.spec_from_file_location("sv", os.path.join(ICI, "..", "reseau", "surveillance.py"))
        sv = importlib.util.module_from_spec(spec); spec.loader.exec_module(sv)
        texte = []                                                  # 1 ligne par disque + 1 ligne de détail
        for l in lignes:
            texte.append(f"{l['texte'][:1]} {l['nom']}")
            texte.append(f"   {l['texte'][2:] if l['niveau'] else l.get('details') or l['texte'][2:]}")
        print("Telegram :", sv.notifier(f"💽 Disques — bilan de la semaine : {bilan}", texte))

if __name__ == "__main__":
    main()
