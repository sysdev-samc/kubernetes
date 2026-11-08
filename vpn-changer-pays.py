#!/usr/bin/env python3
# ROTATION HEBDOMADAIRE DU PAYS DE SORTIE CYBERGHOST (gluetun du pod transmission, partagé avec joal et jackett).
#   1. passe SERVER_COUNTRIES de /ssd1/kubernetes/gluetun/vpn.env au pays suivant de ROTATION
#      (copie de sauvegarde vpn.env.avant-rotation)
#   2. lance vpn-appliquer.sh : Secrets + redémarrage des pods (~1 min de coupure chacun)
#   3. vérifie l'IP et le pays de sortie de chaque gluetun, puis envoie le résultat sur Telegram
# Le gluetun Docker (/ssd1/container/gluetun) n'est PAS concerné : il garde sa propre compose.
#
# Usage : python3 /ssd1/kubernetes/vpn-changer-pays.py               # passe au pays suivant maintenant
#         python3 /ssd1/kubernetes/vpn-changer-pays.py Sweden        # passe à ce pays (nom anglais)
#         python3 /ssd1/kubernetes/vpn-changer-pays.py --etat        # pays et IP de sortie actuels
#         python3 /ssd1/kubernetes/vpn-changer-pays.py --installer   # cron : chaque dimanche à 04:30
#         python3 /ssd1/kubernetes/vpn-changer-pays.py --retirer     # retire le cron
import importlib.util, json, os, re, shutil, subprocess, sys, time, urllib.request

ICI = os.path.dirname(os.path.abspath(__file__))
VPN_ENV = os.path.join(ICI, "gluetun", "vpn.env")
APPLIQUER = os.path.join(ICI, "vpn-appliquer.sh")
CRON = "/etc/cron.d/vpn-changer-pays"
SERVICES = ["transmission"]       # seul gluetun : joal et jackett sont dans le pod transmission
# Hors d'Europe uniquement (choix de l'utilisateur, 17/10/2026). Noms tels que gluetun les attend.
ROTATION = ["Canada", "Morocco", "United Arab Emirates", "Singapore"]
# Pays refusés, même demandés à la main : toute l'Europe (liste des pays européens de CyberGhost)
INTERDITS = {"Albania", "Andorra", "Armenia", "Austria", "Belarus", "Belgium", "Bosnia and Herzegovina", "Bulgaria",
             "Croatia", "Cyprus", "Czech Republic", "Denmark", "Estonia", "Finland", "France", "Georgia", "Germany",
             "Greece", "Greenland", "Hungary", "Iceland", "Ireland", "Isle of Man", "Italy", "Latvia", "Liechtenstein",
             "Lithuania", "Luxembourg", "Macedonia", "Malta", "Moldova", "Monaco", "Montenegro", "Netherlands",
             "Norway", "Poland", "Portugal", "Romania", "Russian Federation", "Serbia", "Slovakia", "Slovenia",
             "Spain", "Sweden", "Switzerland", "Turkey", "Ukraine", "United Kingdom"}
FR = {"Canada": "Canada", "Morocco": "Maroc", "United Arab Emirates": "Émirats arabes unis", "Singapore": "Singapour",
      "Austria": "Autriche", "Switzerland": "Suisse", "Germany": "Allemagne", "Luxembourg": "Luxembourg",
      "Belgium": "Belgique", "Netherlands": "Pays-Bas", "Denmark": "Danemark", "Norway": "Norvège",
      "Sweden": "Suède", "Finland": "Finlande"}
ENV = {**os.environ, "KUBECONFIG": "/etc/rancher/k3s/k3s.yaml",
       "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}   # cron n'a pas /usr/local/bin

def pays_actuel():
    m = re.search(r"^SERVER_COUNTRIES=(.*)$", open(VPN_ENV).read(), re.M)
    return m.group(1).strip() if m else ""

def sorties():
    """IP et pays de sortie de chaque gluetun (API de contrôle, port 8000 du pod)."""
    res = {}
    for nom in SERVICES:
        # Seulement les pods en marche : un pod évincé (Failed) garde le label et une IP morte
        ip = subprocess.run(["kubectl", "-n", "media", "get", "pod", "-l", f"app={nom}",
                             "--field-selector=status.phase=Running", "-o",
                             "jsonpath={.items[0].status.podIP}"], capture_output=True, text=True, env=ENV).stdout.strip()
        try:
            d = json.load(urllib.request.urlopen(f"http://{ip}:8000/v1/publicip/ip", timeout=10))
            res[nom] = (d.get("public_ip") or "?", d.get("country") or "?", d.get("city") or "?")
        except Exception:
            res[nom] = ("?", "?", "?")
    return res

def main():
    if "--installer" in sys.argv:
        open(CRON, "w").write("# Rotation hebdomadaire du pays CyberGhost (voir /ssd1/kubernetes/vpn-changer-pays.py)\n"
                              f"30 4 * * 0 root /usr/bin/python3 {os.path.abspath(__file__)} > /var/log/vpn-changer-pays.log 2>&1\n")
        os.chmod(CRON, 0o644); print("Installé :", CRON); print(open(CRON).read(), end=""); return
    if "--retirer" in sys.argv:
        if os.path.exists(CRON): os.remove(CRON)
        print("Retiré :", CRON); return
    if "--etat" in sys.argv:
        print(f"vpn.env : SERVER_COUNTRIES={pays_actuel()}")
        for nom, (ip, pays, ville) in sorties().items(): print(f"{nom:13} sortie {ip} ({ville}, {pays})")
        return

    avant_pays, avant = pays_actuel(), sorties()
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if args:
        nouveau = args[0]
        if nouveau in INTERDITS or nouveau.lower() in {p.lower() for p in INTERDITS}:
            sys.exit(f"{nouveau} est dans les pays refusés : {', '.join(sorted(INTERDITS))}")
    else:
        i = ROTATION.index(avant_pays) if avant_pays in ROTATION else -1
        nouveau = ROTATION[(i + 1) % len(ROTATION)]

    shutil.copy2(VPN_ENV, VPN_ENV + ".avant-rotation")
    texte = open(VPN_ENV).read()
    texte = re.sub(r"^SERVER_COUNTRIES=.*$", f"SERVER_COUNTRIES={nouveau}", texte, flags=re.M) \
        if re.search(r"^SERVER_COUNTRIES=", texte, re.M) else texte.rstrip("\n") + f"\nSERVER_COUNTRIES={nouveau}\n"
    open(VPN_ENV, "w").write(texte)
    print(f"Pays : {avant_pays} -> {nouveau}")

    r = subprocess.run(["bash", APPLIQUER], capture_output=True, text=True, env=ENV, timeout=1200)
    print(r.stdout[-3000:], r.stderr[-1500:])
    time.sleep(20)                           # le temps que les deux tunnels soient remontés
    apres = sorties()

    lignes = [f"🌍 {FR.get(avant_pays, avant_pays)} → {FR.get(nouveau, nouveau)}"]
    ok = r.returncode == 0
    for nom in SERVICES:
        ip_a, ip_n = avant[nom][0], apres[nom]
        bon = ip_n[1].lower() == nouveau.lower()
        ok &= bon
        lignes.append(f"{'✅' if bon else '❌'} {nom} : {ip_a} → {ip_n[0]} ({ip_n[2]}, {ip_n[1]})")
    if not ok:
        lignes.append(f"⚠️ problème : voir /var/log/vpn-changer-pays.log ; retour arrière possible : "
                      f"python3 {os.path.abspath(__file__)} {avant_pays}")
    print("\n".join(lignes))
    spec = importlib.util.spec_from_file_location("sv", os.path.join(ICI, "reseau", "surveillance.py"))
    sv = importlib.util.module_from_spec(spec); spec.loader.exec_module(sv)
    print("Notification :", sv.notifier("🔄 Changement de pays VPN (CyberGhost)", lignes))

if __name__ == "__main__":
    main()
