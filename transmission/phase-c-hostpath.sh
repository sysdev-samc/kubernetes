#!/bin/bash
# PHASE C : /downloads quitte Longhorn pour le disque local (/volume1/downloads) de chaque nœud,
# pour transmission, radarr ET sonarr. Plus de réplication de /downloads, mais les fichiers
# sont visibles directement dans le partage réseau du NAS. Coupure ~5 min.
# Comme pour /movies, les 3 services doivent tourner sur le MÊME nœud (bascule-kubernetes.sh
# les déplace ensemble) ; sur nas1, /downloads sera le /volume1/downloads de nas1.
#
# Le volume Longhorn "downloads" n'est PAS supprimé (filet de sécurité). Une fois validé :
#   kubectl -n media delete pvc downloads
# (sinon bascule-kubernetes.sh refuse de basculer : un volume détaché n'est pas "healthy").
#
# Retour arrière : git checkout des 3 fichiers 03-deployment.yaml + kubectl apply.
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K8S=/ssd1/kubernetes
cd "$K8S/transmission"

read -r -p "Prêt pour ~5 min de coupure (transmission, radarr, sonarr) ? [o/N] " rep
[ "$rep" = "o" ] || exit 1

echo "=== C0. Les 3 déploiements doivent utiliser le hostPath"
for f in 03-deployment.yaml "$K8S/radarr/03-deployment.yaml" "$K8S/sonarr/03-deployment.yaml"; do
  grep -q 'claimName: downloads' "$f" && { echo "ERREUR : $f utilise encore le PVC downloads"; exit 1; }
  grep -q 'path: /volume1/downloads,' "$f" || { echo "ERREUR : $f n'a pas le hostPath /volume1/downloads"; exit 1; }
done
[ "$(kubectl get node nas2 -o jsonpath='{.spec.unschedulable}')" = true ] && { echo "ERREUR : nas2 est cordonné"; exit 1; }

echo; echo "=== C1. Arrêt de transmission, radarr et sonarr"
kubectl -n media scale deploy/transmission deploy/radarr deploy/sonarr --replicas=0
kubectl -n media wait --for=delete pod -l 'app in (transmission,radarr,sonarr)' --timeout=180s || true

echo; echo "=== C2. Copie Longhorn -> /volume1/downloads (nas2)"
kubectl apply -f 06-migration-hostpath.yaml
while phase=$(kubectl -n media get pod downloads-vers-hostpath -o jsonpath='{.status.phase}'); [[ "$phase" =~ ^(Pending|Running)$ ]]; do sleep 5; done
if [ "$phase" != Succeeded ]; then
  kubectl -n media logs downloads-vers-hostpath || true
  echo "!!! Copie en échec. Services arrêtés, volume Longhorn intact."
  echo "    Retour arrière : git -C $K8S checkout transmission/03-deployment.yaml radarr/03-deployment.yaml sonarr/03-deployment.yaml"
  echo "    puis kubectl apply des 3 fichiers (ils remettent replicas: 1)."
  exit 1
fi
kubectl -n media logs downloads-vers-hostpath
kubectl -n media delete pod downloads-vers-hostpath

echo; echo "=== C3. Redémarrage sur nas2 avec le hostPath (fin de la coupure)"
# nas1 interdit le temps du démarrage : les 3 pods doivent arriver sur nas2, là où sont les fichiers
kubectl cordon nas1
trap 'kubectl uncordon nas1' EXIT
kubectl apply -f 03-deployment.yaml -f "$K8S/radarr/03-deployment.yaml" -f "$K8S/sonarr/03-deployment.yaml"
for d in transmission radarr sonarr; do kubectl -n media rollout status deploy/$d --timeout=420s; done
kubectl uncordon nas1; trap - EXIT
kubectl -n media get pods -o wide -l 'app in (transmission,radarr,sonarr)'

echo; echo "=== Tests"
maison=$(curl -s -m 5 https://ipinfo.io/country)
vpn=$(kubectl -n media exec deploy/transmission -c transmission -- curl -s -m 8 https://ipinfo.io/country || true)
[ -n "$vpn" ] && [ "$vpn" != "$maison" ] && echo "VPN : OK ($vpn, pas $maison)" || echo "VPN : PROBLÈME ($vpn)"
for s in transmission radarr sonarr; do
  echo "$s /downloads : $(kubectl -n media exec deploy/$s -c $s -- df -h /downloads | awk 'NR==2{print $1}')  $(kubectl -n media exec deploy/$s -c $s -- ls /downloads/complete | tr '\n' ' ')"
done
echo "sur le disque de nas2 :"; du -sh /volume1/downloads/complete

echo
echo "=== À faire maintenant :"
echo " 1. http://192.168.1.150:9091 : les torrents sont là et en seed / reprise ?"
echo " 2. Les fichiers sont visibles dans /volume1/downloads/complete (partage réseau)"
echo " 3. Quand tout est OK : kubectl -n media delete pvc downloads"
