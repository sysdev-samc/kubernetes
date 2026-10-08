#!/bin/bash
# Déploie ou met à jour Homepage (à relancer après chaque modification de 01-config.yaml
# ou de manuel.env). Coupure de quelques secondes de la page seulement.
# Usage : bash /ssd1/kubernetes/homepage/deploy.sh
set -e -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"
echo "=== Secret (clés API)"; bash ./00-secret.sh
echo; echo "=== Ressources"
kubectl apply -f 02-rbac.yaml -f 01-config.yaml -f 03-deployment.yaml -f 04-service.yaml
# La config et le Secret ne sont relus qu'au démarrage : on redémarre le pod
kubectl -n media rollout restart deploy/homepage
kubectl -n media rollout status deploy/homepage --timeout=300s
kubectl -n media get pods -l app=homepage -o wide
echo; echo "=== Test"
echo "http://192.168.1.150 : $(curl -s -m10 -o /dev/null -w '%{http_code}' http://192.168.1.150/)  (200 = OK)"
echo "Erreurs dans les logs : $(kubectl -n media logs deploy/homepage --since=2m | grep -ciE 'error')"
kubectl -n media logs deploy/homepage --since=2m | grep -iE 'error' | sed -E 's/(key|token|apikey)=[^& ]+/\1=***/Ig' | tail -5 | cut -c1-180
