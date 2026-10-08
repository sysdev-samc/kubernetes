#!/bin/bash
# Compare les versions des images installées dans le namespace "media"
# avec la dernière version publiée (GitHub, ou Docker Hub pour mariadb). Ne modifie rien.
# Usage : bash /ssd1/kubernetes/check-versions.sh
#
# Compte GitHub : si "gh" est connecté (gh auth login), son jeton est utilisé
# -> 5000 requêtes/heure au lieu de 60. Sinon, on interroge GitHub anonymement.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

TOKEN=$(gh auth token 2>/dev/null)
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")

# image -> où chercher sa dernière version
#   gh:<dépôt>         dernière "release" GitHub
#   hub:<image>:<motif> plus haut tag Docker Hub correspondant au motif (regex)
#   ignore              image utilitaire, non suivie
source_of() {
  case "$1" in
    lscr.io/linuxserver/*)             echo "gh:linuxserver/docker-${1#lscr.io/linuxserver/}" ;;
    qmcgaw/gluetun)                    echo "gh:qdm12/gluetun" ;;
    ghcr.io/gethomepage/homepage)      echo "gh:gethomepage/homepage" ;;
    ghcr.io/flaresolverr/flaresolverr) echo "gh:FlareSolverr/FlareSolverr" ;;
    ghcr.io/seerr-team/seerr)          echo "gh:seerr-team/seerr" ;;
    mariadb)                           echo "hub:library/mariadb:${2%.*}" ;;   # reste sur la même branche (ex. 10.11)
    busybox)                           echo "ignore" ;;
    *)                                 echo "" ;;
  esac
}

declare -A CACHE   # une seule requête par source, même si l'image sert plusieurs fois (gluetun)
latest_of() {
  local src=$1
  [ -n "${CACHE[$src]+x}" ] && { echo "${CACHE[$src]}"; return; }
  local v=""
  case "$src" in
    gh:*)  v=$(curl -sL -m8 "${AUTH[@]}" "https://api.github.com/repos/${src#gh:}/releases/latest" |
               python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name") or "")' 2>/dev/null) ;;
    hub:*) local s=${src#hub:}; local img=${s%:*} branche=${s##*:}
           v=$(curl -s -m8 "https://hub.docker.com/v2/repositories/$img/tags?page_size=100&name=$branche." |
               python3 -c 'import json,sys,re
b=sys.argv[1]; t=[x["name"] for x in json.load(sys.stdin)["results"] if re.fullmatch(re.escape(b)+r"\.\d+", x["name"])]
print(max(t, key=lambda v: [int(p) for p in v.split(".")]) if t else "")' "$branche" 2>/dev/null) ;;
  esac
  CACHE[$src]=$v
  echo "$v"
}

if [ -n "$TOKEN" ]; then echo "GitHub : compte connecté (gh)"; else echo "GitHub : anonyme (60 requêtes/heure) — 'gh auth login' pour plus"; fi
echo
printf '%-17s %-17s %-24s %-24s %s\n' DEPLOYMENT CONTENEUR INSTALLÉE DISPONIBLE ""
while read -r d c img; do
  name=${img%:*}; tag=${img##*:}
  src=$(source_of "$name" "$tag")
  if [ "$src" = ignore ]; then latest="-"; etat="(non suivie)"
  elif [ -z "$src" ]; then latest="?"; etat="source inconnue : à ajouter dans source_of"
  else
    latest=$(latest_of "$src")
    if   [ -z "$latest" ];        then latest="?"; etat="échec de la requête (réseau ou quota)"
    elif [ "$tag" = "$latest" ];  then etat="à jour"
    else                               etat="<- MISE À JOUR DISPONIBLE"
    fi
  fi
  printf '%-17s %-17s %-24s %-24s %s\n' "$d" "$c" "$tag" "$latest" "$etat"
done < <(for d in $(kubectl -n media get deploy -o jsonpath='{.items[*].metadata.name}'); do
           kubectl -n media get deploy "$d" -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name} {.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.name} {.image}{"\n"}{end}' | sed "s/^/$d /"
         done)

[ -n "$TOKEN" ] && curl -s -m8 "${AUTH[@]}" https://api.github.com/rate_limit |
  python3 -c 'import json,sys; r=json.load(sys.stdin)["rate"]; print("\nQuota GitHub restant : %d / %d" % (r["remaining"], r["limit"]))' 2>/dev/null
echo
echo "Notes de version : https://github.com/<dépôt>/releases  (ex. linuxserver/docker-radarr, qdm12/gluetun)"
