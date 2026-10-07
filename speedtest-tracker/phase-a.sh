#!/bin/bash
# PHASE A : MariaDB + speedtest-tracker dans k8s, EN PARALLÈLE du Docker (aucune coupure).
# La copie k8s n'a PAS de tests programmés : elle affiche l'historique, c'est tout.
# Usage : bash /ssd1/kubernetes/speedtest-tracker/phase-a.sh
set -e -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"
OLD_DB=speedtest-tracker-db-1
count_old() { docker exec $OLD_DB sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -N -e "select count(*) from results" "$MARIADB_DATABASE"'; }
count_new() { kubectl -n media exec deploy/speedtest-db -- sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -N -e "select count(*) from results" "$MARIADB_DATABASE"'; }

echo "=== A1. Secret (copie de APP_KEY et du mot de passe, compose Docker non modifiée)"
bash ./00-secret.sh

echo; echo "=== A2. MariaDB"
kubectl apply -f 01-pvc.yaml
kubectl -n media wait pvc/speedtest-db pvc/speedtest-tracker-config --for=jsonpath='{.status.phase}'=Bound --timeout=120s
kubectl apply -f 02-db.yaml
kubectl -n media rollout status deploy/speedtest-db --timeout=300s

echo; echo "=== A3. Export SQL de la base Docker -> import dans la base k8s"
docker exec $OLD_DB sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --single-transaction --routines --triggers "$MARIADB_DATABASE"' \
  | kubectl -n media exec -i deploy/speedtest-db -- sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
echo "résultats : Docker = $(count_old)  |  k8s = $(count_new)"

echo; echo "=== A4. Copie de /config"
kubectl apply -f 03-migration-pod.yaml
kubectl -n media wait pod/speedtest-migration --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl -n media logs speedtest-migration | tail -1
kubectl -n media delete pod speedtest-migration

echo; echo "=== A5. Application (sans tests programmés)"
grep -q 'PHASE-A-SCHEDULE' 04-app.yaml || { echo "ERREUR : 04-app.yaml n'est plus en mode phase A"; exit 1; }
kubectl apply -f 04-app.yaml
kubectl -n media rollout status deploy/speedtest-tracker --timeout=300s
kubectl -n media get pods -o wide -l 'app in (speedtest-db,speedtest-tracker)'

echo; echo "=== A6. Tests"
echo "toi -> 192.168.1.150:5080 : $(curl -s -m5 http://192.168.1.150:5080/api/healthcheck)"
echo "programmation de tests dans la copie : $(kubectl -n media exec deploy/speedtest-tracker -- printenv SPEEDTEST_SCHEDULE 2>/dev/null || echo 'aucune (bon)')"
echo "erreurs base dans les logs : $(kubectl -n media logs deploy/speedtest-tracker | grep -ciE 'SQLSTATE|connection refused')"
echo
echo "Compare http://192.168.1.150:5080 (k8s) avec http://192.168.1.2:5080 (Docker) : connexion, historique, graphiques."
