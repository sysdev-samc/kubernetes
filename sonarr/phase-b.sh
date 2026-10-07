#!/bin/bash
# PHASE B : bascule finale du sonarr Docker vers sonarr k8s (~3-5 min de coupure).
# Prérequis (étape B1, dans l'interface du sonarr Docker http://192.168.1.2:8989) :
#   - System -> Backup -> Backup Now
# Usage : bash /ssd1/kubernetes/sonarr/phase-b.sh
#
# Retour arrière si besoin APRÈS ce script :
#   kubectl -n media scale deploy/sonarr --replicas=0
#   systemctl unmask sonarr && systemctl enable --now sonarr
#   (puis remettre 192.168.1.2 dans Seer)
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"

read -r -p "As-tu fait 'Backup Now' dans le sonarr Docker à l'instant ? [o/N] " rep
[ "$rep" = "o" ] || { echo "Fais d'abord le Backup Now, puis relance."; exit 1; }

echo; echo "=== B2. Arrêt définitif du sonarr Docker (début de la coupure)"
systemctl stop sonarr
# Liens créés par Ansible (font échouer 'systemctl disable') : on les retire
rm -f /etc/systemd/system/multi-user.target.wants/sonarr.service /etc/systemd/system/sonarr.service
systemctl daemon-reload
systemctl mask sonarr
docker rm sonarr 2>/dev/null || true
echo "sonarr.service : $(systemctl is-enabled sonarr 2>&1)   (attendu : masked)"

echo; echo "=== B3. Arrêt de sonarr k8s puis restauration de la sauvegarde fraîche"
kubectl -n media scale deploy/sonarr --replicas=0
kubectl -n media wait --for=delete pod -l app=sonarr --timeout=120s || true
kubectl apply -f 02-migration-pod.yaml
kubectl -n media wait pod/sonarr-migration --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl -n media logs sonarr-migration | grep -E 'Sauvegarde utilisée|RESTAURATION_OK'
read -r -p "La sauvegarde utilisée est-elle bien celle d'aujourd'hui ? [o/N] " rep
if [ "$rep" != "o" ]; then
  echo "ARRÊT. Retour au sonarr Docker pour refaire un 'Backup Now' :"
  kubectl -n media delete pod sonarr-migration
  systemctl unmask sonarr
  systemctl start sonarr
  echo "Le Docker redémarre (http://192.168.1.2:8989). Fais Backup Now puis relance ce script."
  exit 1
fi
kubectl -n media delete pod sonarr-migration

echo; echo "=== B4. Retrait des protections de la phase parallèle"
sed -i -e '/PHASE PARALLÈLE/d' -e 's/, readOnly: true }/ }/' 03-deployment.yaml
if grep -n 'readOnly\|PARALLÈLE' 03-deployment.yaml; then
  echo "ERREUR : il reste des lignes ci-dessus dans 03-deployment.yaml"; exit 1
fi
kubectl delete -f 06-parallel-netpol.yaml --ignore-not-found
kubectl apply -f 03-deployment.yaml
kubectl -n media rollout status deploy/sonarr --timeout=300s
kubectl -n media get pods -o wide -l app=sonarr

echo; echo "=== Tests (fin de la coupure)"
kubectl -n media exec deploy/sonarr -- sh -c '
  touch /tv/.t && rm /tv/.t && echo "tv: écriture OK" || echo "tv: LECTURE SEULE (pas bon)"
  code=$(timeout 4 curl -s -o /dev/null -w "%{http_code}" http://192.168.1.2:9091/transmission/rpc)
  [ "$code" = "409" ] || [ "$code" = "401" ] && echo "transmission: joignable ($code, bon)" || echo "transmission: KO ($code)"
  code=$(timeout 4 curl -s -o /dev/null -w "%{http_code}" http://192.168.1.2:9117/)
  [ "$code" != "000" ] && echo "jackett: joignable ($code, bon)" || echo "jackett: KO"'

echo
echo "=== À faire maintenant dans les interfaces :"
echo " B5. http://192.168.1.150:8989 -> System > Status (pas d'avertissement read-only / communicate)"
echo "     Settings > Download Clients et Indexers : Test -> vert"
echo "     Settings > General > Allowed Hosts : 192.168.1.150, localhost"
echo " B6. Seer > Settings > Services > Sonarr : hôte 192.168.1.150, Test, Save"
