#!/bin/bash
# Crée (ou met à jour) le Secret "joal" à partir de /ssd1/kubernetes/joal/joal.env (ignoré par git) :
#   JOAL_UI_PREFIX        chemin de l'interface      -> http://192.168.1.150:12345/<prefix>/ui/
#   JOAL_UI_SECRET_TOKEN  "secret token" demandé par l'interface (le mot de passe)
# Au premier lancement, joal.env est créé avec les valeurs de l'ancienne compose Docker.
# Les valeurs ne sont jamais affichées. Après modification : relancer ce script puis
#   kubectl -n media rollout restart deploy/joal
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
ENV=/ssd1/kubernetes/joal/joal.env
OLD=/ssd1/container/joal/docker-compose.yml

if [ ! -f "$ENV" ]; then
  prefix=$(grep -o 'joal.ui.path.prefix=[^"]*' "$OLD" | cut -d= -f2)
  token=$(grep -o 'joal.ui.secret-token=[^"]*' "$OLD" | cut -d= -f2)
  [ -n "$prefix" ] && [ -n "$token" ] || { echo "ERREUR : prefix/token introuvables dans $OLD -> crée $ENV à la main"; exit 1; }
  ( umask 077; printf 'JOAL_UI_PREFIX=%s\nJOAL_UI_SECRET_TOKEN=%s\n' "$prefix" "$token" > "$ENV" )
  echo "$ENV créé depuis $OLD"
fi
chmod 600 "$ENV"

kubectl -n media create secret generic joal --from-env-file="$ENV" --dry-run=client -o yaml | kubectl apply -f -
echo "Variables du Secret joal :"
kubectl -n media get secret joal -o go-template='{{range $k, $v := .data}}  {{$k}}{{"\n"}}{{end}}'
