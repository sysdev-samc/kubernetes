#!/bin/bash
# PHASE A : transmission + gluetun dans k8s, en parallèle du Docker (aucune coupure).
# Ce transmission démarre VIDE (aucun torrent) : on valide le VPN, l'accès web,
# le volume partagé /downloads et la communication avec radarr. Rien n'est téléchargé.
# Usage : bash /ssd1/kubernetes/transmission/phase-a.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"

echo "=== A0. Identifiants VPN -> fichier d'environnement puis Secret"
[ -f /ssd1/kubernetes/gluetun/vpn.env ] || { echo "ERREUR : /ssd1/kubernetes/gluetun/vpn.env absent"; exit 1; }
bash ./00-secret.sh

echo; echo "=== A1. Volumes Longhorn (config + /downloads partagé)"
kubectl apply -f 01-pvc.yaml
kubectl -n media wait pvc/transmission-config pvc/downloads --for=jsonpath='{.status.phase}'=Bound --timeout=120s

echo; echo "=== A2. Démarrage du pod gluetun + transmission (le VPN peut prendre 1-2 min)"
grep -q 'PHASE-A-WATCH' 03-deployment.yaml || { echo "ERREUR : 03-deployment.yaml n'est plus en mode phase A"; exit 1; }
kubectl apply -f 03-deployment.yaml
kubectl apply -f 04-service.yaml
kubectl -n media rollout status deploy/transmission --timeout=420s
kubectl -n media get pods -o wide -l app=transmission

echo; echo "=== A3. Tests"
echo "--- VPN"
kubectl -n media logs deploy/transmission -c gluetun | grep -iE 'public ip address' | tail -1 || true
maison=$(curl -s -m 5 https://ipinfo.io/country)
vpn=$(kubectl -n media exec deploy/transmission -c transmission -- curl -s -m 8 https://ipinfo.io/country || true)
echo "pays IP maison : $maison  |  pays IP de transmission : $vpn"
[ -n "$vpn" ] && [ "$vpn" != "$maison" ] && echo "VPN : OK (transmission ne sort PAS avec ton IP)" || echo "VPN : PROBLÈME"
echo "--- Accès"
echo "toi -> http://192.168.1.150:9091 : $(curl -s -o /dev/null -m 5 -w '%{http_code}' http://192.168.1.150:9091/transmission/rpc)  (409 = OK)"
echo "radarr -> http://transmission:9091 : $(kubectl -n media exec deploy/radarr -- curl -s -o /dev/null -m 5 -w '%{http_code}' http://transmission:9091/transmission/rpc)  (409 ou 421 = joignable)"
echo "--- /downloads partagé (Longhorn RWX)"
kubectl -n media exec deploy/transmission -c transmission -- sh -c 'touch /downloads/.test-rwx && rm /downloads/.test-rwx && echo "écriture : OK"'
kubectl -n longhorn-system get pods -l longhorn.io/component=share-manager -o wide --no-headers | awk '{print "share-manager (serveur NFS de Longhorn) : "$3" sur "$7}'

echo; echo "=== Terminé. http://192.168.1.150:9091 = transmission VIDE (normal en phase A)."
echo "Le transmission Docker continue de travailler normalement."
