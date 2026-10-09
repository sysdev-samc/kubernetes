#!/bin/bash
# Installe ou met à jour Headlamp, puis enregistre le jeton de connexion dans jeton.txt.
# Usage : bash /ssd1/kubernetes/headlamp/deploy.sh
set -e -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"
echo "=== Ressources"
kubectl apply -f 01-rbac.yaml -f 02-deployment.yaml -f 03-service.yaml
kubectl -n media rollout status deploy/headlamp --timeout=300s
kubectl -n media get pods -l app=headlamp -o wide

echo; echo "=== Jeton de connexion"
for i in $(seq 1 15); do   # Kubernetes remplit le Secret en quelques secondes
  JETON=$(kubectl -n media get secret headlamp-moi-jeton -o jsonpath='{.data.token}' | base64 -d)
  [ -n "$JETON" ] && break; sleep 1
done
( umask 077; printf '%s\n' "$JETON" > jeton.txt )
echo "Jeton enregistré dans $(pwd)/jeton.txt (droits 600, ignoré par git) : ${#JETON} caractères"
unset JETON

echo; echo "=== Test"
echo "http://192.168.1.150:4466 : $(curl -s -m10 -o /dev/null -w '%{http_code}' http://192.168.1.150:4466/)  (200 = OK)"
echo; echo "=== Homepage (ajout de la carte Headlamp)"
bash ../homepage/deploy.sh
