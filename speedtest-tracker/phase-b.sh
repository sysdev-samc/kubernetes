#!/bin/bash
# PHASE B : bascule finale de speedtest-tracker (Docker -> k8s). Coupure ~2 min.
# Les fichiers de /ssd1/container/speedtest-tracker ne sont PAS modifiés :
# "docker compose down" supprime seulement les conteneurs (ils ne redémarreront plus au boot).
# Retour arrière :
#   kubectl -n media scale deploy/speedtest-tracker --replicas=0
#   cd /ssd1/container/speedtest-tracker && docker compose up -d
set -e -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"
OLD=/ssd1/container/speedtest-tracker
OLD_DB=speedtest-tracker-db-1
count_old() { docker exec $OLD_DB sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -N -e "select count(*) from results" "$MARIADB_DATABASE"'; }
count_new() { kubectl -n media exec deploy/speedtest-db -- sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -N -e "select count(*) from results" "$MARIADB_DATABASE"'; }

read -r -p "Phase A validée, prêt pour ~2 min de coupure ? [o/N] " rep
[ "$rep" = "o" ] || exit 1

echo; echo "=== B1. Arrêt de l'application Docker (plus aucune écriture dans la base)"
docker stop speedtest-tracker

echo; echo "=== B2. Export SQL final -> import dans la base k8s"
docker exec $OLD_DB sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --single-transaction --routines --triggers "$MARIADB_DATABASE"' \
  | kubectl -n media exec -i deploy/speedtest-db -- sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
o=$(count_old); n=$(count_new)
echo "résultats : Docker = $o  |  k8s = $n"
[ "$o" = "$n" ] || { echo "ERREUR : nombres différents -> on s'arrête (relance le Docker : docker start speedtest-tracker)"; exit 1; }

echo; echo "=== B3. Suppression des conteneurs Docker (compose et données inchangées)"
docker compose --project-directory "$OLD" down
docker ps -a --format '{{.Names}}' | grep -E '^speedtest-tracker' && { echo "ERREUR : conteneur encore présent"; exit 1; } || echo "conteneurs Docker : supprimés"

echo; echo "=== B4. Activation des tests programmés dans k8s"
sed -i -e '/PHASE PARALLÈLE : pas de tests programmés/d' -e 's/# PHASE-A-SCHEDULE //' 04-app.yaml
grep -q 'PHASE-A-SCHEDULE\|PHASE PARALLÈLE' 04-app.yaml && { echo "ERREUR : 04-app.yaml non modifié"; exit 1; }
grep -n 'SPEEDTEST_SCHEDULE' 04-app.yaml
kubectl apply -f 04-app.yaml
kubectl -n media rollout status deploy/speedtest-tracker --timeout=300s
kubectl -n media get pods -o wide -l 'app in (speedtest-db,speedtest-tracker)'

echo; echo "=== Tests"
echo "toi -> 192.168.1.150:5080 : $(curl -s -m5 http://192.168.1.150:5080/api/healthcheck)"
echo "programmation : $(kubectl -n media exec deploy/speedtest-tracker -- printenv SPEEDTEST_SCHEDULE)"
echo
echo "=== À faire : favoris 192.168.1.2:5080 -> 192.168.1.150:5080"
echo "    Le prochain test automatique aura lieu à la prochaine demi-heure (xx:00 ou xx:30)."
