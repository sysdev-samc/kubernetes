#!/bin/bash
# BASCULE des services du namespace "media" vers le nœud choisi (nas1 ou nas2).
#
# Principe : on interdit temporairement l'AUTRE nœud (cordon), on redémarre les services
# (ils ne peuvent aller que sur le nœud choisi), puis on lève l'interdiction.
# Les pods RESTENT sur le nœud choisi jusqu'à leur prochain redémarrage (mise à jour,
# reboot...) ; ils reviendront alors sur nas2, leur nœud préféré (voir 03-deployment.yaml).
#
# Usage (sur nas1 ou nas2) :
#   bash /ssd1/kubernetes/bascule-kubernetes.sh nas1                  # tout sur nas1
#   bash /ssd1/kubernetes/bascule-kubernetes.sh nas2                  # tout sur nas2
#   bash /ssd1/kubernetes/bascule-kubernetes.sh nas1 --maintenance    # + nas2 reste interdit
#   bash /ssd1/kubernetes/bascule-kubernetes.sh nas1 --verifier       # vérifications seules, rien ne bouge
#   ... 2>&1 | tee /tmp/bascule.log                                   # pour garder une trace
#
# Sécurités : place disque et marques du nœud cible, volumes Longhorn, retour automatique
# sur le nœud de départ si les services ne sont pas prêts en 5 min ou en cas d'erreur.
set -eE -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=media
VIP=192.168.1.150
TIMEOUT=300               # secondes max pour que tout soit prêt sur la cible, sinon retour
MARGE_IMAGES_GO=10        # place minimale (Go) pour les images sur la cible
MARGE_SYSTEME_GO=2        # place minimale (Go) sur le disque système de la cible

# ---------------------------------------------------------------------------- arguments
TARGET=$1; MODE=$2
case "$TARGET" in
  nas1) OTHER=nas2 ;;
  nas2) OTHER=nas1 ;;
  *) sed -n '9,14p' "$0"; exit 1 ;;
esac
case "$MODE" in ""|--maintenance|--verifier) ;; *) echo "Option inconnue : $MODE"; exit 1 ;; esac

# ---------------------------------------------------------------------------- outils
on_node() {       # exécute une commande sur un nœud (en local si c'est cette machine)
  if [ "$1" = "$(hostname -s)" ]; then bash -c "$2"; else ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" "$2"; fi
}
taints_of()     { kubectl get node "$1" -o json | python3 -c 'import json,sys; print(" ".join(t["key"] for t in json.load(sys.stdin)["spec"].get("taints",[]) if t["key"]!="node.kubernetes.io/unschedulable"))'; }
is_cordoned()   { [ "$(kubectl get node "$1" -o jsonpath='{.spec.unschedulable}')" = true ]; }
is_ready()      { kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; }
disk_of() {       # "images_libre_Go système_libre_Go" vus par Kubernetes
  kubectl get --raw "/api/v1/nodes/$1/proxy/stats/summary" | python3 -c '
import json,sys; n=json.load(sys.stdin)["node"]
print(n["runtime"]["imageFs"]["availableBytes"]//10**9, n["fs"]["availableBytes"]//10**9)'
}
volumes_ok()    { [ "$(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' | grep -vc healthy)" = 0 ]; }
images()        { kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u; }
pods_on()       { kubectl -n $NS get pods --field-selector "spec.nodeName=$1,status.phase=Running" --no-headers 2>/dev/null | wc -l; }
pods_total()    { kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' | paste -sd+ | bc; }
show_pods()     { kubectl -n $NS get pods -o wide --no-headers | awk '{printf "  %-38s %-6s %-18s %s\n", $1, $2, $3, $7}'; }

all_ready() {
  kubectl -n $NS get deploy -o json | python3 -c '
import json,sys
ok=all(d["status"].get("observedGeneration",0)>=d["metadata"]["generation"]
       and d["status"].get("updatedReplicas",0)==d["spec"]["replicas"]
       and d["status"].get("availableReplicas",0)==d["spec"]["replicas"]
       and d["status"].get("replicas",0)==d["spec"]["replicas"]
       for d in json.load(sys.stdin)["items"])
sys.exit(0 if ok else 1)'
}

# Déplace tout vers $1 : interdit l'autre nœud, redémarre, attend (max $2 s).
# Surveille les marques du nœud cible. Retour 0 = OK, 1 = délai dépassé, 2 = marque sur la cible.
move_to() {
  local dest=$1 max=$2 src t0
  [ "$dest" = nas1 ] && src=nas2 || src=nas1
  is_cordoned "$dest" && kubectl uncordon "$dest"
  kubectl cordon "$src"; CORDONED=$src
  t0=$(date +%s)
  kubectl -n $NS rollout restart deploy >/dev/null
  sleep 5
  while true; do
    if all_ready && [ "$(pods_on "$dest")" = "$(pods_total)" ]; then
      echo "Tous les services sont prêts sur $dest en $(( $(date +%s) - t0 )) s."; show_pods; return 0
    fi
    if [ -n "$(taints_of "$dest")" ]; then echo "!!! $dest a reçu une marque : $(taints_of "$dest")"; return 2; fi
    if [ $(( $(date +%s) - t0 )) -ge "$max" ]; then echo "!!! Pas prêts sur $dest après $max s :"; show_pods; return 1; fi
    sleep 5
  done
}

release() {       # lève l'interdiction posée par move_to (sauf en mode maintenance)
  if [ -n "$CORDONED" ] && [ "$MODE" != --maintenance ]; then kubectl uncordon "$CORDONED"; CORDONED=; fi
}

FAILS=0
check() {
  if [[ "$2" =~ ^($3)$ ]]; then printf '  OK  %-22s %s\n' "$1" "$2"
  else printf '  KO  %-22s %s (attendu : %s)\n' "$1" "${2:-rien}" "$3"; FAILS=$((FAILS+1)); fi
}
tests() {
  FAILS=0
  local home c; home=$(curl -s -m5 https://ipinfo.io/country)
  check radarr          "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:7878/ping)" 200
  check sonarr          "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: localhost' http://$VIP:8989/ping)" 200
  check transmission    "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:9091/transmission/rpc)" 409
  check jackett         "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:9117/)" 301
  check seer            "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:5055/api/v1/settings/public)" 200
  check speedtest       "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$VIP:5080/api/healthcheck)" 200
  for s in transmission jackett; do
    c=$(kubectl -n $NS exec deploy/$s -c $s -- curl -s -m8 https://ipinfo.io/country 2>/dev/null || true)
    if [ -n "$c" ] && [ "$c" != "$home" ]; then printf '  OK  %-22s %s (maison %s)\n' "VPN $s" "$c" "$home"
    else printf '  KO  %-22s %s (maison %s)\n' "VPN $s" "${c:-rien}" "$home"; FAILS=$((FAILS+1)); fi
  done
  check "radarr->transmission" "$(kubectl -n $NS exec deploy/radarr -- curl -s -m5 -o /dev/null -w '%{http_code}' http://transmission:9091/transmission/rpc 2>/dev/null)" 409
  check "sonarr->jackett"      "$(kubectl -n $NS exec deploy/sonarr -- curl -s -m5 -o /dev/null -w '%{http_code}' http://jackett:9117/ 2>/dev/null)" 301
  check "seer->radarr"         "$(kubectl -n $NS exec deploy/seer -- wget -q -T5 -O- http://$VIP:7878/ping 2>/dev/null | tr -d ' \n')" '\{"status":"OK"\}'
  check "/downloads partagé"   "$(kubectl -n $NS exec deploy/radarr -- sh -c 'test -d /downloads/complete && echo oui' 2>/dev/null)" oui
  echo "  => $FAILS échec(s)"
}

# ------------------------------------------------- secours automatique (erreur, Ctrl+C)
CORDONED=
START_NODE=
secours() {
  trap - ERR INT
  echo; echo "!!! Interruption ou erreur."
  if [ -n "$CORDONED" ]; then
    echo "    Retour automatique sur $START_NODE."
    move_to "$START_NODE" 600 || echo "!!! Retour incomplet : kubectl -n $NS get pods -o wide"
    kubectl uncordon "$TARGET" 2>/dev/null || true; kubectl uncordon "$OTHER" 2>/dev/null || true
  fi
  exit 1
}
trap secours ERR INT

# ---------------------------------------------------------------- 0. VÉRIFICATIONS
echo "=== Bascule vers $TARGET ${MODE:+($MODE)}"
echo; echo "=== 0. Vérifications"
is_ready "$TARGET" || { echo "$TARGET n'est pas Ready"; exit 1; }
[ -z "$(taints_of "$TARGET")" ] || { echo "$TARGET porte une marque : $(taints_of "$TARGET")"; exit 1; }
volumes_ok || { echo "Au moins un volume Longhorn n'est pas 'healthy' (une seule copie) : on ne bascule pas."; exit 1; }
read -r imgfree sysfree < <(disk_of "$TARGET")
echo "$TARGET : images ${imgfree} Go libres, système ${sysfree} Go libres ; $(images | wc -l) images à prévoir"
[ "$imgfree" -ge $MARGE_IMAGES_GO ] || { echo "Pas assez de place pour les images sur $TARGET (< $MARGE_IMAGES_GO Go)"; exit 1; }
[ "$sysfree" -ge $MARGE_SYSTEME_GO ] || { echo "Pas assez de place système sur $TARGET (< $MARGE_SYSTEME_GO Go)"; exit 1; }
on=$(pods_on "$TARGET"); total=$(pods_total)
echo "Services déjà sur $TARGET : $on / $total"
# Nœud de départ = celui qui porte le plus de pods (pour un éventuel retour automatique)
[ "$(pods_on nas1)" -ge "$(pods_on nas2)" ] && START_NODE=nas1 || START_NODE=nas2
if all_ready; then
  echo "--- tests de départ"; tests
else
  echo "ATTENTION : tous les services ne sont pas prêts actuellement."; FAILS=1
fi

if [ "$MODE" = --verifier ]; then trap - ERR INT; echo; echo "=== Mode vérification : rien n'a été déplacé."; exit 0; fi

if [ "$on" = "$total" ] && all_ready; then
  echo; echo "Tous les services sont déjà sur $TARGET."
  if [ "$MODE" = --maintenance ] && ! is_cordoned "$OTHER"; then kubectl cordon "$OTHER"; echo "$OTHER interdit (maintenance)."; fi
  trap - ERR INT; exit 0
fi
if [ "$FAILS" != 0 ]; then
  read -r -p $'\nDes contrôles échouent DÉJÀ avant la bascule. Basculer quand même ? [o/N] ' r; [ "$r" = o ] || exit 1
fi

# ---------------------------------------------------------------- 1. IMAGES
echo; echo "=== 1. Pré-téléchargement des images sur $TARGET (sans coupure)"
for img in $(images); do
  on_node "$TARGET" "k3s crictl pull $img >/dev/null" && echo "  ok : $img"
  [ -z "$(taints_of "$TARGET")" ] || { echo "!!! $TARGET a reçu une marque : $(taints_of "$TARGET"). Arrêt AVANT bascule."; exit 1; }
done

read -r -p $'\nBasculer TOUS les services sur '"$TARGET"$' (~1-2 min de coupure) ? [o/N] ' r
[ "$r" = o ] || { trap - ERR INT; exit 0; }

# ---------------------------------------------------------------- 2. BASCULE
echo; echo "=== 2. Bascule vers $TARGET (retour automatique sur $START_NODE si pas prêt en $TIMEOUT s)"
if ! move_to "$TARGET" $TIMEOUT; then
  echo "La bascule n'a pas abouti : retour automatique sur $START_NODE."
  trap - ERR INT
  move_to "$START_NODE" 600 || true
  kubectl uncordon "$TARGET" 2>/dev/null || true; kubectl uncordon "$OTHER" 2>/dev/null || true
  exit 1
fi
release
echo; echo "--- tests sur $TARGET"; tests

# ---------------------------------------------------------------- 3. BILAN
trap - ERR INT
echo; echo "=== Bilan"
for n in nas1 nas2; do echo "  $n : $(pods_on $n) pod(s)$(is_cordoned $n && echo ', INTERDIT (cordon)')"; done
if [ "$MODE" = --maintenance ]; then
  echo "  Mode maintenance : $OTHER reste interdit. Quand la maintenance est finie :"
  echo "      kubectl uncordon $OTHER     (puis, pour revenir : bash $0 $OTHER)"
fi
if [ "$TARGET" = nas1 ]; then
  echo "  Rappel : sur nas1, radarr/sonarr voient des dossiers films/séries VIDES (disque de nas2)."
  echo "  Ne lance pas 'Update All'/'Rescan', et un import terminé irait sur le disque de nas1."
else
  on_node nas1 'for d in /volume1/cinema/parent/movies /volume1/cinema/parent/tvshow; do [ -d $d ] && n=$(ls -A $d | wc -l) && [ "$n" != 0 ] && echo "  ATTENTION : $n élément(s) importé(s) sur le disque de nas1 dans $d -> à déplacer vers nas2"; done; true'
fi
echo "  Les services resteront sur $TARGET jusqu'à leur prochain redémarrage (préférence : nas2)."
echo; echo "=== Terminé."
