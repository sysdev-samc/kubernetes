#!/bin/bash
# Applique le contenu de /ssd1/kubernetes/gluetun/vpn.env à tous les gluetun.
# À lancer après CHAQUE modification de vpn.env (fournisseur, pays, identifiants...).
#   1. met à jour les Secrets gluetun-env / gluetun-certs
#   2. redémarre le pod transmission, seul pod avec un gluetun (transmission + joal + jackett) : ~1 min de coupure
# (L'ancien gluetun Docker, /ssd1/container/gluetun.sav, n'est plus utilisé.)
# Usage : bash /ssd1/kubernetes/vpn-appliquer.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K8S=/ssd1/kubernetes

echo "=== 1. Secrets"
bash "$K8S/transmission/00-secret.sh"

echo; echo "=== 2. Pods k8s avec gluetun"
# Un seul pod a un gluetun : transmission (avec joal et jackett dedans, un seul tunnel CyberGhost)
out=$(kubectl apply -f "$K8S/transmission/03-deployment.yaml")
echo "$out"
# Si le fichier n'a pas changé, apply ne redémarre rien : on force le redémarrage
# pour que le pod relise le Secret (les variables d'env ne sont lues qu'au démarrage).
echo "$out" | grep -q unchanged && kubectl -n media rollout restart deploy/transmission
kubectl -n media rollout status deploy/transmission --timeout=420s

echo; echo "=== 3. Ancien Secret gluetun-vpn"
if kubectl -n media get deploy -o yaml | grep -q 'gluetun-vpn'; then
  echo "encore utilisé, conservé"
else
  kubectl -n media delete secret gluetun-vpn --ignore-not-found
fi

# Pays de sortie d'un pod (jusqu'à 6 essais : le tunnel peut mettre un moment à être utilisable)
pays_de() {
  local c i
  for i in 1 2 3 4 5 6; do
    c=$(kubectl -n media exec deploy/transmission -c $1 -- curl -s -m8 https://ipinfo.io/country 2>/dev/null) && [ -n "$c" ] && { echo "$c"; return; }
    sleep 10
  done
  echo "? (pas de réponse)"
}
echo; echo "=== 4. Pays de sortie"
echo "maison          : $(curl -s -m5 https://ipinfo.io/country)"
kubectl -n media get deploy transmission >/dev/null 2>&1 && \
  echo "transmission    : $(pays_de transmission)"
echo "jackett         : $(pays_de jackett)"
echo "joal            : $(pays_de joal)"
docker ps --format '{{.Names}}' | grep -qx gluetun && \
  echo "gluetun Docker  : $(docker exec gluetun wget -qO- -T 8 https://ipinfo.io/country)   (config Docker séparée, non modifiée)"
echo "(SERVER_COUNTRIES dans vpn.env : $(grep '^SERVER_COUNTRIES=' /ssd1/kubernetes/gluetun/vpn.env | cut -d= -f2))"
