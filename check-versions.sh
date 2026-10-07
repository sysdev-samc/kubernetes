#!/bin/bash
# Compare les versions des images installées dans le namespace "media"
# avec la dernière version publiée sur GitHub. Ne modifie rien.
# Usage : bash /ssd1/kubernetes/check-versions.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# image -> dépôt GitHub qui publie ses versions
repo_of() {
  case "$1" in
    lscr.io/linuxserver/*) echo "linuxserver/docker-${1#lscr.io/linuxserver/}" ;;
    qmcgaw/gluetun)        echo "qdm12/gluetun" ;;
    *)                     echo "" ;;
  esac
}

printf '%-14s %-14s %-24s %-24s %s\n' DEPLOYMENT CONTENEUR INSTALLÉE DISPONIBLE ""
for d in $(kubectl -n media get deploy -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n media get deploy "$d" -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name} {.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.name} {.image}{"\n"}{end}' |
  while read -r c img; do
    name=${img%:*}; tag=${img##*:}
    repo=$(repo_of "$name")
    latest=$([ -n "$repo" ] && curl -sL -m8 "https://api.github.com/repos/$repo/releases/latest" |
             python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name") or "?")' 2>/dev/null)
    [ "$tag" = "$latest" ] && etat="à jour" || etat="<- MISE À JOUR DISPONIBLE"
    printf '%-14s %-14s %-24s %-24s %s\n' "$d" "$c" "$tag" "${latest:-?}" "$etat"
  done
done
echo
echo "Notes de version : https://github.com/<dépôt>/releases  (ex. linuxserver/docker-radarr, qdm12/gluetun)"
