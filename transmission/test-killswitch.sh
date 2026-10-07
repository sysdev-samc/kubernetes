#!/bin/bash
# Test du "kill switch" : on coupe volontairement le VPN et on vérifie que transmission
# n'a PLUS accès à Internet (au lieu de passer par ta connexion normale = fuite).
# Le VPN est rallumé automatiquement à la fin, même en cas d'erreur ou de Ctrl+C.
# Coupure des téléchargements : ~20 secondes.
# Usage : bash /ssd1/kubernetes/transmission/test-killswitch.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
T="kubectl -n media exec deploy/transmission -c transmission --"
# Serveur de contrôle de gluetun (port 8000, dans le pod, donc joignable en localhost)
vpn() { $T curl -s -m5 -X PUT -H 'Content-Type: application/json' \
          -d "{\"status\":\"$1\"}" http://127.0.0.1:8000/v1/openvpn/status; echo; }
ip_transmission() { $T curl -s -m8 https://ipinfo.io/country 2>/dev/null; }

trap 'echo; echo "=== Rallumage du VPN"; vpn running' EXIT

maison=$(curl -s -m5 https://ipinfo.io/country)
echo "=== 1. Avant : maison = $maison, transmission = $(ip_transmission)"

echo; echo "=== 2. Coupure du VPN"
vpn stopped
sleep 5

echo; echo "=== 3. Transmission essaie d'aller sur Internet sans VPN..."
res=$(ip_transmission)
if [ -z "$res" ]; then
  echo "    aucune réponse -> KILL SWITCH OK : sans VPN, transmission est coupé d'Internet"
elif [ "$res" = "$maison" ]; then
  echo "    réponse : $res -> FUITE ! transmission sort avec ton IP maison"
else
  echo "    réponse : $res -> le VPN n'a pas été coupé, test non concluant"
fi

trap - EXIT
echo; echo "=== 4. Rallumage du VPN"
vpn running
for i in $(seq 1 24); do
  sleep 5
  res=$(ip_transmission)
  [ -n "$res" ] && break
done
echo "=== 5. Après : transmission = ${res:-pas encore reconnecté (attends 1 min et revérifie)}"
