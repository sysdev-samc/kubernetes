#!/bin/bash
# PHASE B : bascule finale de transmission (Docker -> k8s) et passage de /downloads
# sur Longhorn pour transmission, radarr ET sonarr. Coupure ~5 min.
# Le gluetun Docker reste en marche (proxy HTTP, Shadowsocks, joal).
#
# Retour arrière APRÈS ce script :
#   kubectl -n media scale deploy/transmission --replicas=0
#   systemctl unmask transmission && systemctl enable --now transmission
#   puis remettre hostPath /volume1/downloads dans radarr/sonarr 03-deployment.yaml (demander à Claude)
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K8S=/ssd1/kubernetes
cd "$K8S/transmission"

read -r -p "Phase A validée et prêt pour ~5 min de coupure (transmission, radarr, sonarr) ? [o/N] " rep
[ "$rep" = "o" ] || exit 1

echo; echo "=== B1. Arrêt définitif du transmission Docker"
systemctl stop transmission
rm -f /etc/systemd/system/multi-user.target.wants/transmission.service /etc/systemd/system/transmission.service
systemctl daemon-reload
systemctl mask transmission
docker rm -f transmission 2>/dev/null || true
echo "transmission.service : $(systemctl is-enabled transmission 2>&1)   (attendu : masked)"
echo "gluetun Docker : $(docker inspect gluetun --format '{{.State.Status}}')   (doit rester running)"

echo; echo "=== B2. Arrêt de transmission, radarr et sonarr dans k8s"
kubectl -n media scale deploy/transmission deploy/radarr deploy/sonarr --replicas=0
kubectl -n media wait --for=delete pod -l 'app in (transmission,radarr,sonarr)' --timeout=180s || true

echo; echo "=== B3. Copie de la config et de /volume1/downloads vers Longhorn"
kubectl apply -f 02-migration-pod.yaml
kubectl -n media wait pod/transmission-migration --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
kubectl -n media logs transmission-migration
kubectl -n media delete pod transmission-migration

echo; echo "=== B4. Modification des fichiers"
# transmission : active le dossier watch
sed -i 's/# PHASE-A-WATCH //' 03-deployment.yaml
grep -q 'PHASE-A-WATCH' 03-deployment.yaml && { echo "ERREUR : watch non activé"; exit 1; }
grep -n 'mountPath: /watch' 03-deployment.yaml
# radarr et sonarr : /downloads passe du disque de nas2 au volume Longhorn partagé
for s in radarr sonarr; do
  sed -i 's|hostPath: { path: /volume1/downloads, type: DirectoryOrCreate }|persistentVolumeClaim: { claimName: downloads }   # Longhorn RWX partagé (nas1 + nas2)|' "$K8S/$s/03-deployment.yaml"
  grep -q '/volume1/downloads' "$K8S/$s/03-deployment.yaml" && { echo "ERREUR : $s utilise encore /volume1/downloads"; exit 1; }
  echo "$s : $(grep -n 'claimName: downloads' "$K8S/$s/03-deployment.yaml")"
done

echo; echo "=== B5. Redémarrage (fin de la coupure)"
kubectl apply -f 03-deployment.yaml -f "$K8S/radarr/03-deployment.yaml" -f "$K8S/sonarr/03-deployment.yaml"
for d in transmission radarr sonarr; do kubectl -n media rollout status deploy/$d --timeout=420s; done
kubectl -n media get pods -o wide

echo; echo "=== Tests"
maison=$(curl -s -m 5 https://ipinfo.io/country)
vpn=$(kubectl -n media exec deploy/transmission -c transmission -- curl -s -m 8 https://ipinfo.io/country || true)
[ -n "$vpn" ] && [ "$vpn" != "$maison" ] && echo "VPN : OK ($vpn, pas $maison)" || echo "VPN : PROBLÈME ($vpn)"
echo "torrents chargés : $(kubectl -n media exec deploy/transmission -c transmission -- sh -c 'ls /config/torrents | wc -l')"
for s in radarr sonarr; do
  echo "$s -> transmission : $(kubectl -n media exec deploy/$s -- curl -s -o /dev/null -m 5 -w '%{http_code}' http://transmission:9091/transmission/rpc)  (409 = OK)"
  echo "$s voit /downloads : $(kubectl -n media exec deploy/$s -- ls /downloads | tr '\n' ' ')"
done

echo
echo "=== À faire maintenant dans les interfaces :"
echo " 1. http://192.168.1.150:9091 : tes torrents sont là ?"
echo " 2. radarr (:7878) ET sonarr (:8989) > Settings > Download Clients > Transmission :"
echo "      Host = transmission   Port = 9091   -> Test -> Save"
echo " 3. radarr et sonarr > System > Status : pas d'erreur sur le client de téléchargement"
echo " 4. Dépose un .torrent de test dans le dossier watch (partage réseau) -> il apparaît dans transmission"
