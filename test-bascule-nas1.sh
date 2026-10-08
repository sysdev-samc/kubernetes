#!/bin/bash
# TEST DE BASCULE CONTRÔLÉE : tous les services du namespace "media" passent de nas2 à nas1,
# on vérifie qu'ils fonctionnent, puis ils reviennent sur nas2.
# nas2 reste allumé : on lui interdit seulement d'accueillir des pods ("cordon").
# Coupure : ~1-2 min à l'aller, ~1-2 min au retour.
#
# Version 2 (après l'incident du 07/10, nas1 saturé par les images) :
#  - vérifie la PLACE DISQUE de nas1 telle que Kubernetes la voit, et toute marque (taint) ;
#  - surveille "disk-pressure" pendant le pré-téléchargement ET pendant la bascule ;
#  - RETOUR AUTOMATIQUE sur nas2 si les services ne sont pas prêts en 5 min sur nas1,
#    si nas1 reçoit une marque, ou en cas d'erreur / Ctrl+C ;
#  - les tests donnent un verdict OK/KO (et pas seulement des chiffres).
#
# Usage (dans ton terminal, sur nas2) :
#   bash /ssd1/kubernetes/test-bascule-nas1.sh 2>&1 | tee /tmp/bascule.log
set -eE -o pipefail   # -E : le secours se déclenche aussi pour une erreur dans une fonction
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=media
VIP=192.168.1.150
TIMEOUT_NAS1=300          # secondes max pour que tout soit prêt sur nas1, sinon retour
MARGE_IMAGES_GO=10        # place minimale (Go) à garder libre pour les images sur nas1
N1="ssh -o BatchMode=yes -o ConnectTimeout=10 nas1"
CORDONED=0

# ---------------------------------------------------------------------------- outils
nas1_taints() { kubectl get node nas1 -o jsonpath='{.spec.taints}'; }

nas1_disk() {     # "imagefs_libre_Go nodefs_libre_Go" vus par Kubernetes sur nas1
  kubectl get --raw /api/v1/nodes/nas1/proxy/stats/summary | python3 -c '
import json,sys; n=json.load(sys.stdin)["node"]
print(n["runtime"]["imageFs"]["availableBytes"]//10**9, n["fs"]["availableBytes"]//10**9)'
}

volumes_ok() {    # tous les volumes Longhorn "healthy" (2 copies)
  [ "$(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' | grep -vc healthy)" = 0 ]
}

all_ready() {     # tous les deployments à jour et disponibles
  kubectl -n $NS get deploy -o json | python3 -c '
import json,sys
ok=all(d["status"].get("observedGeneration",0)>=d["metadata"]["generation"]
       and d["status"].get("updatedReplicas",0)==d["spec"]["replicas"]
       and d["status"].get("availableReplicas",0)==d["spec"]["replicas"]
       and d["status"].get("replicas",0)==d["spec"]["replicas"]
       for d in json.load(sys.stdin)["items"])
sys.exit(0 if ok else 1)'
}

show_pods() { kubectl -n $NS get pods -o wide --no-headers | awk '{printf "  %-38s %-6s %-18s %s\n", $1, $2, $3, $7}'; }

# Redémarre tout et attend. $1 = délai max (s), $2 = "surveiller-nas1" pour guetter disk-pressure.
# Retourne 0 si prêt, 1 si délai dépassé, 2 si nas1 a reçu une marque.
restart_and_wait() {
  local max=$1 watch=$2 t0=$(date +%s)
  kubectl -n $NS rollout restart deploy >/dev/null
  sleep 5
  while true; do
    if all_ready; then echo "Tous les services sont prêts en $(( $(date +%s) - t0 )) s."; show_pods; return 0; fi
    if [ "$watch" = surveiller-nas1 ] && [ -n "$(nas1_taints)" ]; then echo "!!! nas1 a reçu une marque : $(nas1_taints)"; return 2; fi
    if [ $(( $(date +%s) - t0 )) -ge "$max" ]; then echo "!!! Pas prêts après $max s :"; show_pods; return 1; fi
    sleep 5
  done
}

retour_nas2() {   # retour sur nas2 (utilisé aussi en secours)
  echo; echo "=== Retour sur nas2"
  kubectl uncordon nas2; CORDONED=0
  restart_and_wait 600 "" || echo "!!! Services toujours pas prêts : kubectl -n $NS get pods -o wide"
}

FAILS=0
check() {         # check <nom> <obtenu> <attendu (regex)>
  if [[ "$2" =~ ^($3)$ ]]; then printf '  OK  %-22s %s\n' "$1" "$2"
  else printf '  KO  %-22s %s (attendu : %s)\n' "$1" "${2:-rien}" "$3"; FAILS=$((FAILS+1)); fi
}

tests() {
  FAILS=0
  local home; home=$(curl -s -m5 https://ipinfo.io/country)
  check radarr          "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:7878/ping)" 200
  check sonarr          "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: localhost' http://$VIP:8989/ping)" 200
  check transmission    "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:9091/transmission/rpc)" 409
  check jackett         "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:9117/)" 301
  check seer            "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:5055/api/v1/settings/public)" 200
  check speedtest       "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:5080/api/healthcheck)" 200
  check "VPN transmission" "$(kubectl -n $NS exec deploy/transmission -c transmission -- curl -s -m8 https://ipinfo.io/country 2>/dev/null)" "[A-Z]{2}"
  check "VPN jackett"      "$(kubectl -n $NS exec deploy/jackett -c jackett -- curl -s -m8 https://ipinfo.io/country 2>/dev/null)" "[A-Z]{2}"
  for s in transmission jackett; do   # le pays VPN doit être DIFFÉRENT de celui de la maison
    c=$(kubectl -n $NS exec deploy/$s -c $s -- curl -s -m8 https://ipinfo.io/country 2>/dev/null)
    [ -n "$c" ] && [ "$c" != "$home" ] && printf '  OK  %-22s %s (maison %s)\n' "$s hors maison" "$c" "$home" \
      || { printf '  KO  %-22s %s = maison %s !\n' "$s hors maison" "${c:-rien}" "$home"; FAILS=$((FAILS+1)); }
  done
  check "radarr->transmission" "$(kubectl -n $NS exec deploy/radarr -- curl -s -m5 -o /dev/null -w '%{http_code}' http://transmission:9091/transmission/rpc 2>/dev/null)" 409
  check "sonarr->jackett"      "$(kubectl -n $NS exec deploy/sonarr -- curl -s -m5 -o /dev/null -w '%{http_code}' http://jackett:9117/ 2>/dev/null)" 301
  check "seer->radarr"         "$(kubectl -n $NS exec deploy/seer -- wget -q -T5 -O- http://$VIP:7878/ping 2>/dev/null | tr -d ' \n')" '\{"status":"OK"\}'
  check "/downloads partagé"   "$(kubectl -n $NS exec deploy/radarr -- sh -c 'test -d /downloads/complete && echo oui' 2>/dev/null)" oui
  echo "  => $FAILS échec(s)"
}

# ------------------------------------------------- secours automatique (erreur, Ctrl+C)
secours() {
  trap - ERR INT
  echo; echo "!!! Interruption ou erreur."
  if [ "$CORDONED" = 1 ]; then echo "    nas2 était interdit : retour automatique."; retour_nas2; fi
  exit 1
}
trap secours ERR INT

# ---------------------------------------------------------------- 0. VÉRIFICATIONS
echo "=== 0. Vérifications préalables"
kubectl get node nas1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True || { echo "nas1 n'est pas Ready"; exit 1; }
[ -z "$(nas1_taints)" ] || { echo "nas1 porte une marque : $(nas1_taints)"; exit 1; }
[ -z "$(kubectl get node nas2 -o jsonpath='{.spec.unschedulable}')" ] || { echo "nas2 est déjà interdit (cordon) : situation anormale"; exit 1; }
volumes_ok || { echo "au moins un volume Longhorn n'est pas 'healthy'"; exit 1; }
all_ready  || { echo "tous les services ne sont pas prêts au départ"; exit 1; }
read -r imgfree nodefree < <(nas1_disk)
img_go=$(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u | wc -l)
echo "nas1 : images ${imgfree} Go libres, nœud ${nodefree} Go libres ; $img_go images à prévoir (~4 Go)"
[ "$imgfree" -ge "$MARGE_IMAGES_GO" ] || { echo "Pas assez de place pour les images sur nas1 (< $MARGE_IMAGES_GO Go)"; exit 1; }
[ "$nodefree" -ge 2 ] || { echo "Pas assez de place sur le disque système de nas1 (< 2 Go)"; exit 1; }
echo "--- tests de départ (tout sur nas2)"
tests
[ "$FAILS" = 0 ] || { echo "Des tests échouent AVANT la bascule : on corrige d'abord."; exit 1; }

# ---------------------------------------------------------------- 1. IMAGES SUR NAS1
echo; echo "=== 1. Pré-téléchargement des images sur nas1 (sans impact sur les services)"
for img in $(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u); do
  $N1 "k3s crictl pull $img >/dev/null" && echo "  ok : $img"
  [ -z "$(nas1_taints)" ] || { echo "!!! nas1 a reçu une marque pendant les téléchargements : $(nas1_taints)"; echo "On arrête AVANT toute bascule."; exit 1; }
done
read -r imgfree nodefree < <(nas1_disk); echo "nas1 après téléchargement : images ${imgfree} Go libres"

read -r -p $'\nPrêt à basculer TOUS les services sur nas1 (~1-2 min de coupure) ? [o/N] ' rep
[ "$rep" = "o" ] || exit 0

# ---------------------------------------------------------------- 2. BASCULE
echo; echo "=== 2. Bascule vers nas1 (retour automatique si pas prêt en ${TIMEOUT_NAS1} s)"
kubectl cordon nas2; CORDONED=1
if ! restart_and_wait $TIMEOUT_NAS1 surveiller-nas1; then
  echo "La bascule n'a pas abouti : retour automatique sur nas2."
  retour_nas2; trap - ERR INT; exit 1
fi
on_nas1=$(kubectl -n $NS get pods --field-selector spec.nodeName=nas1 --no-headers | wc -l)
echo "Pods sur nas1 : $on_nas1 / $(kubectl -n $NS get pods --no-headers | wc -l)"
echo; echo "--- tests sur nas1"
tests

# ---------------------------------------------------------------- 3. PAUSE
echo
echo "=== 3. À toi : ouvre les interfaces sur http://$VIP:<port>"
echo "    Normal sur nas1 : radarr/sonarr signalent des dossiers films/séries vides."
echo "    NE LANCE PAS 'Update All' / 'Rescan' dans radarr ou sonarr."
read -r -p $'\nAppuie sur Entrée pour revenir sur nas2... '

# ---------------------------------------------------------------- 4. RETOUR
retour_nas2
echo; echo "--- tests après retour"
tests

# ---------------------------------------------------------------- 5. CONTRÔLES FINAUX
echo; echo "=== 5. Contrôles finaux"
echo "Attente des volumes Longhorn 'healthy' (jusqu'à 10 min)..."
kubectl -n longhorn-system wait volumes.longhorn.io --all --for=jsonpath='{.status.robustness}'=healthy --timeout=600s >/dev/null \
  && echo "  OK  tous les volumes healthy" || echo "  KO  des volumes ne sont pas healthy : kubectl -n longhorn-system get volumes.longhorn.io"
$N1 'for d in /volume1/cinema/parent/movies /volume1/cinema/parent/tvshow; do [ -d $d ] && echo "  fichiers déposés par erreur sur nas1 dans $d : $(ls -A $d | wc -l) (0 attendu)"; done'
trap - ERR INT
echo; echo "=== Test terminé."
