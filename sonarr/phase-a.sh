#!/bin/bash
# PHASE A : sonarr k8s en parallèle du sonarr Docker (aucune coupure).
# Prérequis (étape A0, dans l'interface du sonarr Docker http://192.168.1.2:8989) :
#   - Indexers / Download Clients : "jackett" et "transmission" remplacés par 192.168.1.2
#   - System -> Backup -> Backup Now
# Usage : bash /ssd1/kubernetes/sonarr/phase-a.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"

read -r -p "As-tu fait l'étape A0 (IP à la place des noms + Backup Now) ? [o/N] " rep
[ "$rep" = "o" ] || { echo "Fais d'abord A0, puis relance."; exit 1; }

echo; echo "=== A1. Disque Longhorn + pare-feu (AVANT de démarrer sonarr)"
kubectl apply -f 01-pvc.yaml
kubectl apply -f 06-parallel-netpol.yaml

echo; echo "=== A1. Restauration de la dernière sauvegarde"
kubectl apply -f 02-migration-pod.yaml
kubectl -n media wait pod/sonarr-migration --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl -n media logs sonarr-migration | grep -E 'Sauvegarde utilisée|RESTAURATION_OK'
kubectl -n media delete pod sonarr-migration

echo; echo "=== A1. Démarrage de sonarr"
kubectl apply -f 03-deployment.yaml
kubectl apply -f 04-service.yaml
kubectl -n media rollout status deploy/sonarr --timeout=300s
kubectl -n media get pods -o wide -l app=sonarr

echo; echo "=== A2. Test des protections"
kubectl -n media exec deploy/sonarr -- sh -c '
  touch /tv/.t 2>/dev/null && echo "tv: ÉCRITURE (pas bon)" || echo "tv: lecture seule (bon)"
  timeout 4 curl -s -o /dev/null http://192.168.1.2:9091/ && echo "transmission: JOIGNABLE (pas bon)" || echo "transmission: BLOQUÉ (bon)"
  timeout 6 curl -s -o /dev/null https://services.sonarr.tv/ && echo "internet: OK" || echo "internet: KO"'

echo; echo "=== Terminé. Ouvre http://192.168.1.150:8989 et compare avec http://192.168.1.2:8989"
