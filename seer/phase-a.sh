#!/bin/bash
# PHASE A : copie de seer dans k8s, ISOLÉE (pare-feu), en parallèle du seer Docker.
# Le seer Docker (192.168.1.2:5055) continue de fonctionner normalement.
# Usage : bash /ssd1/kubernetes/seer/phase-a.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"

echo "=== A1. Volume + pare-feu (AVANT de démarrer seer)"
kubectl apply -f 01-pvc.yaml
kubectl -n media wait pvc/seer-config --for=jsonpath='{.status.phase}'=Bound --timeout=120s
kubectl apply -f 06-parallel-netpol.yaml

echo; echo "=== A2. Copie de la config (lecture seule de /ssd1/container/seerr/config)"
kubectl apply -f 02-migration-pod.yaml
kubectl -n media wait pod/seer-migration --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl -n media logs seer-migration | tail -3
kubectl -n media delete pod seer-migration

echo; echo "=== A3. Démarrage de seer"
kubectl apply -f 03-deployment.yaml -f 04-service.yaml
kubectl -n media rollout status deploy/seer --timeout=300s
kubectl -n media get pods -o wide -l app=seer

echo; echo "=== A4. Tests"
S="kubectl -n media exec deploy/seer --"
echo "toi -> 192.168.1.150:5055 : $(curl -s -o /dev/null -m5 -w '%{http_code}' http://192.168.1.150:5055/api/v1/settings/public)  (200 = OK)"
$S sh -c 'wget -q -T4 -O /dev/null http://192.168.1.150:7878/ping 2>/dev/null && echo "seer -> radarr (.150)   : JOIGNABLE (pas bon)" || echo "seer -> radarr (.150)   : BLOQUÉ (bon)"'
$S sh -c 'wget -q -T4 -O /dev/null http://radarr.media:7878/ping 2>/dev/null && echo "seer -> radarr (cluster): JOIGNABLE (pas bon)" || echo "seer -> radarr (cluster): BLOQUÉ (bon)"'
$S sh -c 'wget -q -T4 -O /dev/null http://192.168.1.2:5055/ 2>/dev/null && echo "seer -> LAN/Docker      : JOIGNABLE (pas bon)" || echo "seer -> LAN/Docker      : BLOQUÉ (bon)"'
$S sh -c 'wget -q -T8 -O /dev/null https://ipinfo.io/country 2>/dev/null && echo "seer -> Internet (+DNS) : OK" || echo "seer -> Internet (+DNS) : KO"'

echo
echo "=== Compare http://192.168.1.150:5055 (copie k8s) avec http://192.168.1.2:5055 (Docker)"
echo "    connexion, demandes existantes, réglages. NE FAIS PAS de nouvelle demande sur la copie :"
echo "    elle ne partirait pas (pare-feu) et serait écrasée à la bascule."
