#!/bin/bash
# PHASE A : pod jackett (gluetun + jackett + flaresolverr) dans k8s, EN PARALLÈLE des Docker.
# Deux jackett peuvent tourner en même temps sans risque : ils ne font que répondre aux recherches.
# Usage : bash /ssd1/kubernetes/jackett/phase-a.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd /ssd1/kubernetes

echo; echo "=== A2. Copie de la config de jackett"
kubectl apply -f jackett/01-pvc.yaml
kubectl -n media wait pvc/jackett-config --for=jsonpath='{.status.phase}'=Bound --timeout=120s
kubectl apply -f jackett/02-migration-pod.yaml
kubectl -n media wait pod/jackett-migration --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl -n media logs jackett-migration
kubectl -n media delete pod jackett-migration

echo; echo "=== A3. jackett"
kubectl apply -f jackett/03-deployment.yaml -f jackett/04-service.yaml
kubectl -n media rollout status deploy/jackett --timeout=300s
kubectl -n media get pods -o wide -l app=jackett

echo; echo "=== A4. Tests"
echo "jackett -> flaresolverr     : $(kubectl -n media exec deploy/jackett -c jackett -- curl -s -m5 http://localhost:8191/health)  (status ok = OK)"
echo "toi -> 192.168.1.150:9117   : $(curl -s -o /dev/null -m5 -w '%{http_code}' http://192.168.1.150:9117/)  (200/301/302 = OK)"
echo "radarr -> jackett:9117      : $(kubectl -n media exec deploy/radarr -- curl -s -o /dev/null -m5 -w '%{http_code}' http://jackett:9117/)  (200/301/302 = OK)"
echo "sonarr -> jackett:9117      : $(kubectl -n media exec deploy/sonarr -- curl -s -o /dev/null -m5 -w '%{http_code}' http://jackett:9117/)  (200/301/302 = OK)"

echo
echo "=== À faire dans http://192.168.1.150:9117 (le jackett k8s) :"
echo " - ton indexeur est là ? clique sur la clé à molette / 'Test' -> vert"
echo " - fais une recherche manuelle (Manual Search) -> des résultats"
echo "Le jackett Docker (192.168.1.2:9117) continue de servir radarr et sonarr."
