#!/bin/bash
# Crée (ou met à jour) le Secret "speedtest-tracker" depuis /ssd1/kubernetes/speedtest-tracker/secret.env
# (ignoré par git, droits 600) : APP_KEY et DB_PASSWORD. Les valeurs ne sont jamais affichées.
# APP_KEY doit rester celle d'origine (elle chiffre des données de la base) : si secret.env a
# disparu, il est repris de la sauvegarde USB (/media/usb1/ssd1/kubernetes/speedtest-tracker/secret.env).
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
DST=/ssd1/kubernetes/speedtest-tracker/secret.env
SAUVEGARDE=/media/usb1/ssd1/kubernetes/speedtest-tracker/secret.env

if [ ! -f "$DST" ]; then
  if [ -f "$SAUVEGARDE" ]; then cp -p "$SAUVEGARDE" "$DST"; echo "$DST repris de la sauvegarde USB"
  else echo "ERREUR : $DST absent (et pas de sauvegarde USB montée). Il contient APP_KEY=... et DB_PASSWORD=..."; exit 1; fi
fi
chmod 600 "$DST"

kubectl -n media create secret generic speedtest-tracker \
  --from-env-file="$DST" --dry-run=client -o yaml | kubectl apply -f -
echo "Clés du Secret : $(kubectl -n media get secret speedtest-tracker -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}')"
