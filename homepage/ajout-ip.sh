#!/bin/bash
# Ajoute à Homepage l'IP de sortie du VPN (gluetun de transmission) et l'IP publique.
# ATTENTION : redémarre transmission (~1 min, le temps que le VPN se reconnecte).
# Usage : bash /ssd1/kubernetes/homepage/ajout-ip.sh
set -e -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")/.."
echo "=== 1. transmission : ouverture du port 8000 dans le pare-feu de gluetun"
kubectl apply -f transmission/03-deployment.yaml -f transmission/05-service-vpn.yaml
kubectl -n media rollout status deploy/transmission --timeout=360s
echo; echo "=== 2. Test du serveur de contrôle depuis le pod homepage"
kubectl -n media exec deploy/homepage -- node -e 'fetch("http://transmission-vpn.media:8000/v1/publicip/ip").then(r=>r.json()).then(d=>console.log("IP VPN :",d.public_ip,d.city,d.country)).catch(e=>{console.log("ECHEC",e.message);process.exit(1)})'
echo; echo "=== 3. Homepage"
bash homepage/deploy.sh
