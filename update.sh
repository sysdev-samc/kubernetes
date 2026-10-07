#!/bin/bash
# Met à jour l'image d'un conteneur, proprement :
#   1. snapshot Longhorn du volume de config (point de retour arrière)
#   2. changement de version dans <app>/03-deployment.yaml
#   3. kubectl apply + attente du redémarrage
# Usage : bash /ssd1/kubernetes/update.sh <deployment> <conteneur> <nouvelle-version>
#   ex. : bash /ssd1/kubernetes/update.sh radarr radarr 6.4.4.10685-ls319
#         bash /ssd1/kubernetes/update.sh transmission gluetun v3.41.3
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
[ $# -eq 3 ] || { sed -n '6,8p' "$0"; exit 1; }
app=$1; ctr=$2; new=$3
file=/ssd1/kubernetes/$app/03-deployment.yaml
[ -f "$file" ] || { echo "ERREUR : $file introuvable"; exit 1; }

img=$(kubectl -n media get deploy "$app" -o jsonpath="{.spec.template.spec.initContainers[?(@.name=='$ctr')].image}{.spec.template.spec.containers[?(@.name=='$ctr')].image}")
[ -n "$img" ] || { echo "ERREUR : conteneur '$ctr' introuvable dans $app"; exit 1; }
name=${img%:*}; old=${img##*:}
[ "$old" != "$new" ] || { echo "Déjà en version $new."; exit 0; }
echo "=== $app/$ctr : $old -> $new"
read -r -p "As-tu lu les notes de version (changements, migrations) ? [o/N] " rep
[ "$rep" = "o" ] || exit 1

echo; echo "=== 1. Snapshot Longhorn du volume de config (retour arrière possible)"
pv=$(kubectl -n media get pvc "$app-config" -o jsonpath='{.spec.volumeName}')
snap="$app-$(date +%Y%m%d-%H%M%S)"
kubectl apply -f - <<YAML
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata: { name: $snap, namespace: longhorn-system }
spec: { volume: $pv, createSnapshot: true }
YAML
kubectl -n longhorn-system wait snapshots.longhorn.io/$snap --for=jsonpath='{.status.readyToUse}'=true --timeout=120s
echo "Snapshot : $snap (volume $pv)"

echo; echo "=== 2. Nouvelle version dans $file"
sed -i "s|image: $name:$old|image: $name:$new|" "$file"
grep -q "image: $name:$new" "$file" || { echo "ERREUR : remplacement non effectué"; exit 1; }
grep -n "image: $name" "$file"

echo; echo "=== 3. Déploiement"
kubectl apply -f "$file"
if kubectl -n media rollout status deploy/"$app" --timeout=420s; then
  kubectl -n media get pods -l app="$app" -o wide
  echo; echo "OK. Vérifie l'interface et 'kubectl -n media logs deploy/$app -c $ctr'."
else
  echo
  echo "ÉCHEC du démarrage. Retour arrière :"
  echo "  sed -i 's|image: $name:$new|image: $name:$old|' $file && kubectl apply -f $file"
  echo "  Si la base a été convertie, revenir au snapshot (volume détaché) :"
  echo "    kubectl -n media scale deploy/$app --replicas=0"
  echo "    Longhorn UI > Volume $pv > Attach (Maintenance) > snapshot $snap > Revert > Detach"
  echo "    puis remettre l'ancienne version (sed ci-dessus) et kubectl apply"
  exit 1
fi
