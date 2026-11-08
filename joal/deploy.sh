#!/bin/bash
# Installe joal : Secret, volume Longhorn (restauré depuis la sauvegarde Longhorn s'il manque),
# puis (re)démarre le pod transmission qui contient joal, derrière son gluetun.
# joal n'a PAS de gluetun à lui (voir le commentaire dans transmission/03-deployment.yaml).
# Usage : bash /ssd1/kubernetes/joal/deploy.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K8S=/ssd1/kubernetes
cd "$(dirname "$0")"

echo "=== 1. Secret (chemin + mot de passe de l'interface)"
bash ./00-secret.sh

echo; echo "=== 2. Volume Longhorn joal-data"
if kubectl -n media get pvc joal-data >/dev/null 2>&1; then
  echo "volume joal-data déjà présent"
elif bash "$K8S/longhorn-sauvegarde/restaurer-volume.sh" --liste joal-data 2>/dev/null | grep -q "media/joal-data"; then
  echo "volume absent : restauration de la dernière sauvegarde Longhorn"
  bash "$K8S/longhorn-sauvegarde/restaurer-volume.sh" joal-data --oui
else
  echo "volume absent et aucune sauvegarde : volume VIDE (config par défaut de joal)"
  kubectl apply -f 01-pvc.yaml
fi

echo; echo "=== 3. Pod transmission (gluetun + transmission + joal) et service de l'interface"
kubectl apply -f "$K8S/transmission/03-deployment.yaml" -f 04-service.yaml
kubectl -n media rollout status deploy/transmission --timeout=420s

echo; echo "=== 4. Tests"
maison=$(curl -s -m5 https://ipinfo.io/country)
vpn=$(kubectl -n media exec deploy/transmission -c joal -- curl -s -m8 https://ipinfo.io/country || true)
[ -n "$vpn" ] && [ "$vpn" != "$maison" ] && echo "VPN de joal : OK ($vpn, pas $maison)" || echo "VPN de joal : PROBLÈME ($vpn)"
prefix=$(grep '^JOAL_UI_PREFIX=' joal.env | cut -d= -f2)
echo "interface : http://192.168.1.150:12345/$prefix/ui/ -> HTTP $(curl -s -o /dev/null -m5 -w '%{http_code}' http://192.168.1.150:12345/$prefix/ui/)"
