#!/bin/bash
# Branche Longhorn sur la cible NFS (disque USB de nas2). AUCUNE sauvegarde automatique :
# elles se lancent à la main avec sauvegarder-maintenant.sh.
# Prérequis : activer-nfs.sh lancé sur nas2. Usage : bash configurer.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"
URL=nfs://192.168.1.2:/media/usb1/longhorn-backup
echo "=== Cible de sauvegarde : $URL"
kubectl -n longhorn-system patch backuptargets.longhorn.io default --type merge \
  -p "{\"spec\":{\"backupTargetURL\":\"$URL\",\"pollInterval\":\"5m0s\"}}"
for i in $(seq 1 30); do
  [ "$(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}')" = true ] && break; sleep 5
done
kubectl -n longhorn-system get backuptargets.longhorn.io default
[ "$(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}')" = true ] \
  || { echo "ERREUR : cible non disponible :"; kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.conditions}'; exit 1; }
# Pas de sauvegarde automatique (choix du 08/11/2026) : on vérifie qu'aucune n'existe
if [ -n "$(kubectl -n longhorn-system get recurringjobs.longhorn.io -o name 2>/dev/null)" ]; then
  echo "ATTENTION : des tâches planifiées Longhorn existent :"; kubectl -n longhorn-system get recurringjobs.longhorn.io
fi
echo "Prêt. Sauvegarde : bash $(pwd)/sauvegarder-maintenant.sh"
