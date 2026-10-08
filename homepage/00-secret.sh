#!/bin/bash
# Construit le Secret "homepage-env" (variables HOMEPAGE_VAR_*) SANS afficher aucune valeur :
#  - clés lues automatiquement dans les services du cluster : radarr, sonarr, seer
#  - clés à créer toi-même dans les interfaces, à mettre dans manuel.env :
#      HOMEPAGE_VAR_HA_TOKEN        Home Assistant : Profil > Sécurité > Jetons d'accès longue durée
#      HOMEPAGE_VAR_SPEEDTEST_KEY   Speedtest Tracker : Paramètres > API Tokens (droit de lecture)
#      HOMEPAGE_VAR_JACKETT_PASSWORD   mot de passe administrateur de Jackett
set -e -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
DIR=/ssd1/kubernetes/homepage
MANUEL=$DIR/manuel.env          # ignoré par git (*.env), droits 600

if [ ! -f "$MANUEL" ]; then
  ( umask 077; printf '%s\n' \
    "# Clés à créer dans les interfaces (une par ligne, sans guillemets), puis relancer deploy.sh" \
    "HOMEPAGE_VAR_HA_TOKEN=" "HOMEPAGE_VAR_SPEEDTEST_KEY=" "HOMEPAGE_VAR_JACKETT_PASSWORD=" > "$MANUEL" )
  echo "Créé : $MANUEL (à compléter)"
fi
chmod 600 "$MANUEL"

tmp=$(mktemp -d); chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
k() { kubectl -n media exec "deploy/$1" -- sh -c "$2" 2>/dev/null | tr -d '\r\n'; }
k radarr "sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml"  > "$tmp/HOMEPAGE_VAR_RADARR_KEY"
k sonarr "sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml"  > "$tmp/HOMEPAGE_VAR_SONARR_KEY"
k seer   "node -e 'process.stdout.write(require(\"/app/config/settings.json\").main.apiKey)'" > "$tmp/HOMEPAGE_VAR_SEER_KEY"
while IFS='=' read -r key val; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  printf '%s' "$val" > "$tmp/$key"
done < "$MANUEL"

args=(); echo "Variables du Secret homepage-env :"
for f in "$tmp"/*; do
  args+=(--from-file="$(basename "$f")=$f")
  [ -s "$f" ] && echo "  OK    $(basename "$f")" || echo "  VIDE  $(basename "$f")  (widget en erreur tant qu'elle manque)"
done
kubectl -n media create secret generic homepage-env "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
