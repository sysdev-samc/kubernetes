#!/bin/bash
# Passe jackett + flaresolverr derrière le VPN : un seul pod gluetun + jackett + flaresolverr.
# Le service "jackett" (jackett:9117 / 192.168.1.150:9117) ne change pas : radarr et sonarr
# ne voient qu'un redémarrage d'environ 1 min.
# Usage : bash /ssd1/kubernetes/jackett/passage-vpn.sh
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")"

echo "=== 1. Nouveau pod jackett (gluetun + jackett + flaresolverr)"
bash ../transmission/00-secret.sh   # Secrets gluetun-env / gluetun-certs (depuis vpn.env)
kubectl apply -f 03-deployment.yaml
kubectl -n media rollout status deploy/jackett --timeout=420s
kubectl -n media get pods -o wide -l app=jackett
kubectl -n media logs deploy/jackett -c flaresolverr-url

echo; echo "=== 2. Suppression de l'ancien flaresolverr séparé (désormais dans le pod jackett)"
kubectl -n media delete deploy/flaresolverr svc/flaresolverr --ignore-not-found
rm -rf /ssd1/kubernetes/flaresolverr

echo; echo "=== 3. Tests"
J="kubectl -n media exec deploy/jackett -c jackett --"
F="kubectl -n media exec deploy/jackett -c flaresolverr --"
maison=$(curl -s -m5 https://ipinfo.io/country)
echo "pays maison       : $maison"
echo "pays jackett      : $($J curl -s -m8 https://ipinfo.io/country)"
echo "pays flaresolverr : $($F python3 -c "import urllib.request; print(urllib.request.urlopen('https://ipinfo.io/country', timeout=8).read().decode().strip())" 2>/dev/null)"
echo "DNS du pod        : $($J grep nameserver /etc/resolv.conf)"
echo "jackett -> flaresolverr (localhost) : $($J curl -s -m5 http://localhost:8191/health)"
$J sh -c 'grep -h "Using FlareSolverr" /config/Jackett/log.txt | tail -1'
echo "toi -> 192.168.1.150:9117 : $(curl -s -o /dev/null -m5 -w '%{http_code}' http://192.168.1.150:9117/)  (301 = OK)"
for s in radarr sonarr; do
  echo "$s -> jackett:9117 : $(kubectl -n media exec deploy/$s -- curl -s -o /dev/null -m5 -w '%{http_code}' http://jackett:9117/)  (301 = OK)"
done
echo
echo "=== Vérifie dans http://192.168.1.150:9117 : Test de l'indexeur + recherche manuelle."
