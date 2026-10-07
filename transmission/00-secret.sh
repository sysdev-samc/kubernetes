#!/bin/bash
# Crée (ou met à jour) les deux Secrets utilisés par les gluetun du cluster (transmission, jackett) :
#   gluetun-env   <- /ssd1/kubernetes/gluetun/vpn.env (TOUTES ses variables : fournisseur, pays,
#                    identifiants...). Chargé d'un bloc par "envFrom" dans les pods.
#   gluetun-certs <- /ssd1/kubernetes/gluetun/client.crt et client.key (fichiers)
# Les valeurs ne sont jamais affichées.
# Après modification de vpn.env : relancer ce script PUIS redémarrer les pods
# (bash /ssd1/kubernetes/vpn-appliquer.sh fait les deux).
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SRC=/ssd1/kubernetes/gluetun

[ -f "$SRC/vpn.env" ] || { echo "ERREUR : $SRC/vpn.env absent -> crée-le (OPENVPN_USER, OPENVPN_PASSWORD, VPN_SERVICE_PROVIDER, SERVER_COUNTRIES)"; exit 1; }

kubectl -n media create secret generic gluetun-env \
  --from-env-file="$SRC/vpn.env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n media create secret generic gluetun-certs \
  --from-file=client.crt="$SRC/client.crt" \
  --from-file=client.key="$SRC/client.key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Variables dans gluetun-env (sans les valeurs) :"
kubectl -n media get secret gluetun-env -o go-template='{{range $k, $v := .data}}  {{$k}}{{"\n"}}{{end}}'
