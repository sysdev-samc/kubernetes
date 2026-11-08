#!/bin/bash
# Crée (ou met à jour) le Secret "joal" à partir de /ssd1/kubernetes/joal/joal.env (ignoré par git) :
#   JOAL_UI_PREFIX        chemin de l'interface      -> http://192.168.1.150:12345/<prefix>/ui/
#   JOAL_UI_SECRET_TOKEN  "secret token" demandé par l'interface (le mot de passe)
# Si joal.env a disparu, il est repris de la sauvegarde USB (/media/usb1/ssd1/kubernetes/joal/joal.env) ;
# sinon, le recréer à la main avec ces deux lignes (anciennes valeurs : voir le gestionnaire de mots de passe).
# Les valeurs ne sont jamais affichées. Après modification : relancer ce script puis
#   kubectl -n media rollout restart deploy/transmission   (joal tourne dans le pod transmission)
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
ENV=/ssd1/kubernetes/joal/joal.env
SAUVEGARDE=/media/usb1/ssd1/kubernetes/joal/joal.env

if [ ! -f "$ENV" ]; then
  if [ -f "$SAUVEGARDE" ]; then cp -p "$SAUVEGARDE" "$ENV"; echo "$ENV repris de la sauvegarde USB"
  else echo "ERREUR : $ENV absent (et pas de sauvegarde USB montée) -> le créer avec JOAL_UI_PREFIX=... et JOAL_UI_SECRET_TOKEN=..."; exit 1; fi
fi
chmod 600 "$ENV"

kubectl -n media create secret generic joal --from-env-file="$ENV" --dry-run=client -o yaml | kubectl apply -f -
echo "Variables du Secret joal :"
kubectl -n media get secret joal -o go-template='{{range $k, $v := .data}}  {{$k}}{{"\n"}}{{end}}'
