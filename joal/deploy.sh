#!/bin/bash
# Déploie joal (derrière gluetun) dans k8s. Le joal Docker est déjà arrêté.
# Usage : bash /ssd1/kubernetes/joal/deploy.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"

echo "=== 1. Secret (chemin + mot de passe de l'interface)"
bash ./00-secret.sh
kubectl -n media get secret gluetun-env gluetun-certs >/dev/null   # Secrets VPN (transmission/00-secret.sh)

echo; echo "=== 2. Volume Longhorn + copie des données Docker (si vide)"
kubectl apply -f 01-pvc.yaml
if ! kubectl -n media get deploy joal >/dev/null 2>&1; then
  kubectl apply -f 02-migration-pod.yaml
  while phase=$(kubectl -n media get pod joal-migration -o jsonpath='{.status.phase}'); [[ "$phase" =~ ^(Pending|Running)$ ]]; do sleep 3; done
  kubectl -n media logs joal-migration
  kubectl -n media delete pod joal-migration
  [ "$phase" = Succeeded ] || { echo "!!! copie en échec"; exit 1; }
else
  echo "joal déjà déployé : pas de nouvelle copie"
fi

echo; echo "=== 3. Pod gluetun + joal (le VPN peut prendre 1-2 min)"
kubectl apply -f 03-deployment.yaml -f 04-service.yaml
kubectl -n media rollout status deploy/joal --timeout=420s
kubectl -n media get pods -o wide -l app=joal

echo; echo "=== 4. Tests"
maison=$(curl -s -m5 https://ipinfo.io/country)
vpn=$(kubectl -n media exec deploy/joal -c gluetun -- wget -qO- -T 8 https://ipinfo.io/country || true)
[ -n "$vpn" ] && [ "$vpn" != "$maison" ] && echo "VPN : OK ($vpn, pas $maison)" || echo "VPN : PROBLÈME ($vpn)"
prefix=$(grep '^JOAL_UI_PREFIX=' joal.env | cut -d= -f2)
echo "interface : http://192.168.1.150:12345/$prefix/ui/ -> HTTP $(curl -s -o /dev/null -m5 -w '%{http_code}' http://192.168.1.150:12345/$prefix/ui/)"
