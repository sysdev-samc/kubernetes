#!/bin/bash
# Sauvegarde Longhorn IMMÉDIATE d'un ou plusieurs volumes (en plus des sauvegardes automatiques).
# Usage : bash sauvegarder-maintenant.sh                 # tous les PVC Longhorn du cluster
#         bash sauvegarder-maintenant.sh radarr-config   # un PVC du namespace media
#         bash sauvegarder-maintenant.sh -n autre-ns mon-pvc
# Utile avant une mise à jour risquée, ou pour tester une restauration.
set -e -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=media
[ "$1" = -n ] && { NS=$2; shift 2; }
[ "$(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}')" = true ] \
  || { echo "ERREUR : cible de sauvegarde indisponible (disque USB monté ? partage NFS actif ?)"; exit 1; }

if [ $# -gt 0 ]; then
  cibles=$(for p in "$@"; do echo "$NS $p $(kubectl -n "$NS" get pvc "$p" -o jsonpath='{.spec.volumeName}')"; done)
else
  cibles=$(kubectl get pvc -A -o jsonpath='{range .items[?(@.spec.storageClassName=="longhorn")]}{.metadata.namespace} {.metadata.name} {.spec.volumeName}{"\n"}{end}')
fi

horo=$(date +%Y%m%d-%H%M%S); noms=()
while read -r ns pvc vol; do
  [ -n "$vol" ] || continue
  snap="manuel-$horo-${vol: -8}"
  kubectl apply -f - 2>&1 >/dev/null <<EOF | grep -v "Warning: metadata.finalizers" >&2 || true
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata: { name: $snap, namespace: longhorn-system }
spec: { volume: $vol, createSnapshot: true }
EOF
  for i in $(seq 1 60); do
    [ "$(kubectl -n longhorn-system get snapshots.longhorn.io "$snap" -o jsonpath='{.status.readyToUse}' 2>/dev/null)" = true ] && break; sleep 2
  done
  kubectl apply -f - 2>&1 >/dev/null <<EOF | grep -v "Warning: metadata.finalizers" >&2 || true
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata: { name: $snap, namespace: longhorn-system, labels: { backup-volume: $vol } }
spec:
  snapshotName: $snap
  # Enregistrés DANS la sauvegarde (sur l'USB) : permettent de retrouver le PVC même après
  # la perte du cluster (lus par restaurer-volume.sh)
  labels: { "sauvegarde/pvc": "$pvc", "sauvegarde/namespace": "$ns" }
EOF
  echo "lancée : $ns/$pvc ($vol)"; noms+=("$snap|$ns/$pvc")
done <<< "$cibles"

echo "--- attente de la fin des sauvegardes"
echec=0
for n in "${noms[@]}"; do
  b=${n%%|*}; p=${n#*|}
  for i in $(seq 1 360); do
    e=$(kubectl -n longhorn-system get backups.longhorn.io "$b" -o jsonpath='{.status.state}' 2>/dev/null)
    case "$e" in Completed|Error) break ;; esac; sleep 5
  done
  t=$(kubectl -n longhorn-system get backups.longhorn.io "$b" -o jsonpath='{.status.size}' 2>/dev/null)
  printf '  %-10s %-35s %s\n' "${e:-?}" "$p" "$(numfmt --to=iec "${t:-0}" 2>/dev/null)"
  [ "$e" = Completed ] || echec=1
done
exit $echec
