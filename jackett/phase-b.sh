#!/bin/bash
# PHASE B : arrêt définitif de jackett et flaresolverr Docker.
# AVANT de lancer : dans radarr ET sonarr, Settings > Indexers > ton indexeur Jackett :
#   remplacer "http://192.168.1.2:9117" par "http://jackett:9117" dans l'URL -> Test -> Save
# Aucune coupure : radarr et sonarr utilisent déjà le jackett k8s.
# Retour arrière : systemctl unmask jackett flaresolverr && systemctl enable --now jackett flaresolverr
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

read -r -p "As-tu changé l'URL de l'indexeur en http://jackett:9117 dans radarr ET sonarr (Test vert) ? [o/N] " rep
[ "$rep" = "o" ] || exit 1

echo "=== Vérification : le jackett k8s répond à radarr et sonarr"
for s in radarr sonarr; do
  code=$(kubectl -n media exec deploy/$s -- curl -s -o /dev/null -m5 -w '%{http_code}' http://jackett:9117/)
  echo "$s -> jackett:9117 : $code"
  [ "$code" != "000" ] || { echo "ERREUR : $s ne joint pas le jackett k8s, on s'arrête."; exit 1; }
done

echo; echo "=== Arrêt définitif de jackett et flaresolverr Docker"
for s in jackett flaresolverr; do
  systemctl stop $s
  rm -f /etc/systemd/system/multi-user.target.wants/$s.service /etc/systemd/system/$s.service
done
systemctl daemon-reload
systemctl mask jackett flaresolverr
docker rm -f jackett flaresolverr 2>/dev/null || true
for s in jackett flaresolverr; do echo "$s.service : $(systemctl is-enabled $s 2>&1)   (attendu : masked)"; done
docker ps -a --format '{{.Names}}' | grep -xE 'jackett|flaresolverr' && echo "ATTENTION : conteneur encore présent" || echo "conteneurs Docker : supprimés"

echo
echo "=== Terminé. Vérifie dans radarr et sonarr : System > Status, pas d'erreur d'indexeur."
