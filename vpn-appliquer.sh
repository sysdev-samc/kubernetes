#!/bin/bash
# Applique le contenu de /ssd1/kubernetes/gluetun/vpn.env à tous les gluetun.
# À lancer après CHAQUE modification de vpn.env (fournisseur, pays, identifiants...).
#   1. met à jour les Secrets gluetun-env / gluetun-certs
#   2. redémarre les pods k8s qui ont un gluetun (transmission, jackett) : ~1 min de coupure chacun
# Le gluetun Docker (/ssd1/container/gluetun) n'est PAS concerné : il garde sa propre compose.
# Usage : bash /ssd1/kubernetes/vpn-appliquer.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K8S=/ssd1/kubernetes

echo "=== 1. Secrets"
bash "$K8S/transmission/00-secret.sh"

echo; echo "=== 2. Pods k8s avec gluetun"
for app in transmission jackett; do
  if ! grep -q 'name: gluetun$' "$K8S/$app/03-deployment.yaml"; then continue; fi
  if [ "$app" = jackett ] && ! kubectl -n media get deploy jackett -o jsonpath='{.spec.template.spec.initContainers[*].name}' | grep -qw gluetun; then
    echo "jackett : pas encore passé derrière le VPN -> ce sera fait par jackett/passage-vpn.sh"; continue
  fi
  out=$(kubectl apply -f "$K8S/$app/03-deployment.yaml")
  echo "$out"
  # Si le fichier n'a pas changé, apply ne redémarre rien : on force le redémarrage
  # pour que le pod relise le Secret (les variables d'env ne sont lues qu'au démarrage).
  echo "$out" | grep -q unchanged && kubectl -n media rollout restart deploy/$app
  kubectl -n media rollout status deploy/$app --timeout=420s
done

echo; echo "=== 3. Ancien Secret gluetun-vpn"
if kubectl -n media get deploy -o yaml | grep -q 'gluetun-vpn'; then
  echo "encore utilisé, conservé"
else
  kubectl -n media delete secret gluetun-vpn --ignore-not-found
fi

echo; echo "=== 4. Pays de sortie"
echo "maison          : $(curl -s -m5 https://ipinfo.io/country)"
kubectl -n media get deploy transmission >/dev/null 2>&1 && \
  echo "transmission    : $(kubectl -n media exec deploy/transmission -c transmission -- curl -s -m8 https://ipinfo.io/country)"
kubectl -n media get deploy jackett -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null | grep -qw gluetun && \
  echo "jackett         : $(kubectl -n media exec deploy/jackett -c jackett -- curl -s -m8 https://ipinfo.io/country)"
docker ps --format '{{.Names}}' | grep -qx gluetun && \
  echo "gluetun Docker  : $(docker exec gluetun wget -qO- -T 8 https://ipinfo.io/country)   (config Docker séparée, non modifiée)"
echo "(SERVER_COUNTRIES dans vpn.env : $(grep '^SERVER_COUNTRIES=' /ssd1/kubernetes/gluetun/vpn.env | cut -d= -f2))"
