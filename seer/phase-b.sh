#!/bin/bash
# PHASE B : bascule finale de seer (Docker -> k8s). Coupure ~2 min.
# Le fichier /etc/systemd/system/seer.service et /ssd1/container/seer ne sont PAS modifiés :
# le service est seulement arrêté et désactivé.
# Retour arrière : kubectl -n media scale deploy/seer --replicas=0 && systemctl enable --now seer
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"

read -r -p "Phase A validée, prêt pour ~2 min de coupure de seer ? [o/N] " rep
[ "$rep" = "o" ] || exit 1

echo; echo "=== B1. Arrêt et désactivation du seer Docker (fichiers inchangés)"
systemctl disable --now seer
docker ps -a --format '{{.Names}}' | grep -qx seer && { echo "ERREUR : conteneur seer encore présent"; exit 1; }
echo "seer.service : $(systemctl is-enabled seer 2>&1) / $(systemctl is-active seer 2>&1)   (attendu : disabled / inactive)"

echo; echo "=== B2. Copie définitive (seer Docker arrêté = base SQLite cohérente)"
kubectl -n media scale deploy/seer --replicas=0
kubectl -n media wait --for=delete pod -l app=seer --timeout=120s || true
kubectl apply -f 02-migration-pod.yaml
kubectl -n media wait pod/seer-migration --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl -n media logs seer-migration | tail -1
kubectl -n media delete pod seer-migration

echo; echo "=== B3. Retrait du pare-feu et démarrage"
kubectl delete -f 06-parallel-netpol.yaml --ignore-not-found
kubectl apply -f 03-deployment.yaml
kubectl -n media rollout status deploy/seer --timeout=300s
kubectl -n media get pods -o wide -l app=seer

echo; echo "=== Tests"
S="kubectl -n media exec deploy/seer --"
echo "toi -> 192.168.1.150:5055 : $(curl -s -o /dev/null -m5 -w '%{http_code}' http://192.168.1.150:5055/api/v1/settings/public)  (200 = OK)"
echo "seer -> radarr : $($S wget -q -T5 -O- http://192.168.1.150:7878/ping 2>&1 | head -c 40)"
echo "seer -> sonarr : $($S wget -q -T5 -O- http://192.168.1.150:8989/ping 2>&1 | head -c 40)"

echo
echo "=== À faire :"
echo " 1. http://192.168.1.150:5055 : connexion, demandes, Settings > Services > Radarr/Sonarr : Test"
echo " 2. Favoris : 192.168.1.2:5055 -> 192.168.1.150:5055"
echo " 3. Si tu utilises netflix.home.lan (NPM) : c'est à changer dans l'interface de NPM"
echo "    (actuellement 192.168.1.5:5055) -> 192.168.1.150:5055. Je n'y touche pas."
