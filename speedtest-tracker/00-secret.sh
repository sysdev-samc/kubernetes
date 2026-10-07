#!/bin/bash
# COPIE (lecture seule) APP_KEY et le mot de passe de la base depuis la compose Docker
# /ssd1/container/speedtest-tracker/docker-compose.yml (qui n'est PAS modifiée)
# vers /ssd1/kubernetes/speedtest-tracker/secret.env (droits 600), puis crée le Secret k8s.
# Les valeurs ne sont jamais affichées.
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SRC=/ssd1/container/speedtest-tracker/docker-compose.yml
DST=/ssd1/kubernetes/speedtest-tracker/secret.env

if [ ! -f "$DST" ]; then
  umask 077
  python3 - "$SRC" "$DST" <<'PY'
import re, sys
vals = {}
for l in open(sys.argv[1]):
    m = re.match(r'^\s*-\s*(APP_KEY|DB_PASSWORD)=(.*)$', l.rstrip('\n'))
    if m: vals[m.group(1)] = m.group(2).strip().strip('"\'')
assert set(vals) == {'APP_KEY', 'DB_PASSWORD'}, "APP_KEY ou DB_PASSWORD introuvable"
with open(sys.argv[2], 'w') as f:
    for k in ('APP_KEY', 'DB_PASSWORD'): f.write(f"{k}={vals[k]}\n")
PY
  chmod 600 "$DST"
  echo "Créé : $DST"
fi

kubectl -n media create secret generic speedtest-tracker \
  --from-env-file="$DST" --dry-run=client -o yaml | kubectl apply -f -
echo "Clés du Secret : $(kubectl -n media get secret speedtest-tracker -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}')"
