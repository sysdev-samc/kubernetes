#!/bin/bash
# PARTIE 2 : déplace /var/lib/rancher de nas1 (partition /var de 9 Go, trop petite) vers
# /ssd1/rancher, puis le remonte au MÊME chemin par un "montage lié" (bind mount).
# k3s ne voit aucune différence ; les images de conteneurs ont enfin de la place.
#
# À lancer sur nas2 (qui garde le contrôle du cluster pendant que k3s est arrêté sur nas1).
# Les services media (sur nas2) ne sont pas coupés. L'IP 192.168.1.150 peut migrer vers
# nas2 (coupure de quelques secondes de l'accès LAN).
#
# Usage : bash /ssd1/kubernetes/nas1-deplacer-rancher.sh 2>&1 | tee /tmp/nas1-rancher.log
# Reprise après un arrêt à l'étape 3 (k3s déjà arrêté sur nas1) :
#         bash /ssd1/kubernetes/nas1-deplacer-rancher.sh --reprendre-etape4 2>&1 | tee -a /tmp/nas1-rancher.log
# Retour arrière (si k3s ne repart pas sur nas1) :
#         bash /ssd1/kubernetes/nas1-deplacer-rancher.sh --retour-arriere
set -e -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
N1="ssh -o BatchMode=yes -o ConnectTimeout=10 nas1"
OLD=/var/lib/rancher
NEW=/ssd1/rancher
FSTAB_LINE="$NEW  $OLD  none  bind,x-systemd.requires-mounts-for=/ssd1  0  0"

confirm() { read -r -p $'\n'"$1 [o/N] " r; [ "$r" = "o" ] || { echo "Arrêt demandé. $2"; exit 1; }; }

wait_nas1_ready() {
  echo "Attente du retour de nas1 (Ready)..."
  kubectl wait node/nas1 --for=condition=Ready --timeout=600s
  kubectl get --raw '/readyz?verbose' | grep '^\[+\]etcd ok'
}

wait_volumes_healthy() {
  echo "Attente de la reconstruction Longhorn (tous les volumes 'healthy', jusqu'à 30 min)..."
  kubectl -n longhorn-system wait volumes.longhorn.io --all \
    --for=jsonpath='{.status.robustness}'=healthy --timeout=1800s >/dev/null
  kubectl -n longhorn-system get volumes.longhorn.io \
    -o custom-columns='PVC:.status.kubernetesStatus.pvcName,SANTE:.status.robustness' --no-headers | sed 's/^/  /'
}

# ---------------------------------------------------------------- RETOUR ARRIÈRE
if [ "$1" = "--retour-arriere" ]; then
  echo "=== RETOUR ARRIÈRE : remise de $OLD sur la partition /var de nas1"
  $N1 "test -d $OLD.old" || { echo "$OLD.old introuvable sur nas1 : rien à restaurer."; exit 1; }
  confirm "Arrêter k3s sur nas1 et restaurer l'ancien $OLD ?" ""
  kubectl cordon nas1 || true
  $N1 "systemctl stop k3s; /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
       umount $OLD 2>/dev/null || true
       [ -f /etc/fstab.avant-ssd1 ] && cp -p /etc/fstab.avant-ssd1 /etc/fstab
       systemctl daemon-reload
       rmdir $OLD 2>/dev/null || true
       mv $OLD.old $OLD
       systemctl start k3s"
  wait_nas1_ready
  kubectl uncordon nas1
  wait_volumes_healthy
  echo "Retour arrière terminé. Les données copiées restent dans nas1:$NEW (à supprimer à la main)."
  exit 0
fi

STAGE=0
on_error() {
  echo; echo "!!! Erreur ou interruption à l'étape $STAGE."
  if [ "$STAGE" -lt 3 ]; then echo "    k3s tourne encore sur nas1. Si besoin : kubectl uncordon nas1"
  elif [ "$STAGE" -lt 5 ]; then echo "    Rien n'a été basculé. Relancer : ssh nas1 systemctl start k3s && kubectl uncordon nas1"
  else echo "    Si k3s ne repart pas sur nas1 : bash $0 --retour-arriere"; fi
}
trap on_error ERR INT

if [ "$1" = "--reprendre-etape4" ]; then
  echo "=== Reprise à l'étape 4 : vérification que nas1 est bien 'k3s arrêté, rien de basculé'"
  [ "$(kubectl get node nas1 -o jsonpath='{.spec.unschedulable}')" = true ] || { echo "nas1 n'est pas en drain"; exit 1; }
  $N1 "[ \"\$(systemctl is-active k3s)\" != active ] || { echo 'k3s tourne encore sur nas1'; exit 1; }
       if pgrep -f '/usr/local/bin/[k]3s' >/dev/null || pgrep -f '[r]ancher/k3s/agent/etc/containerd' >/dev/null; then echo 'processus k3s encore présents'; exit 1; fi
       if findmnt -rn -o TARGET | grep -q '^$OLD'; then echo 'des montages restent sous $OLD'; exit 1; fi
       ! test -e $NEW && ! test -e $OLD.old && ! grep -q '$OLD' /etc/fstab || { echo 'une bascule semble déjà commencée'; exit 1; }
       echo 'OK : k3s arrêté sur nas1, aucun montage, rien de basculé.'"
  STAGE=3
else
# ---------------------------------------------------------------- 0. VÉRIFICATIONS
echo "=== 0. Vérifications"
kubectl get node nas1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True || { echo "nas1 pas Ready"; exit 1; }
[ -z "$(kubectl get node nas1 -o jsonpath='{.spec.taints}')" ] || { echo "nas1 porte une marque (taint) : $(kubectl get node nas1 -o jsonpath='{.spec.taints}')"; exit 1; }
bad=$(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' | grep -vc healthy || true)
[ "$bad" = 0 ] || { echo "$bad volume(s) Longhorn pas 'healthy' : on attend qu'ils le soient."; exit 1; }
kubectl get --raw '/readyz?verbose' | grep -q '^\[+\]etcd ok' || { echo "etcd pas sain"; exit 1; }
[ "$(kubectl get nodes -l node-role.kubernetes.io/etcd=true --no-headers | grep -c ' Ready')" = 3 ] || { echo "les 3 membres etcd ne sont pas Ready"; exit 1; }
media_on_nas1=$(kubectl -n media get pods --field-selector spec.nodeName=nas1 --no-headers 2>/dev/null | wc -l)
[ "$media_on_nas1" = 0 ] || { echo "$media_on_nas1 pod(s) media tournent sur nas1 : on ne continue pas."; exit 1; }
$N1 "command -v rsync >/dev/null && ! test -e $NEW && ! grep -q '$OLD' /etc/fstab" \
  || { echo "nas1 : rsync absent, ou $NEW existe déjà, ou fstab contient déjà $OLD"; exit 1; }
need=$($N1 "du -sxm $OLD | cut -f1"); free=$($N1 "df -m --output=avail /ssd1 | tail -1")
echo "nas1 : $OLD = ${need} Mo, libre sur /ssd1 = ${free} Mo"
[ "$free" -gt $((need + 10240)) ] || { echo "Pas assez de place sur /ssd1 de nas1"; exit 1; }
echo "OK : nas1 Ready sans marque, volumes healthy, etcd 3/3, aucun service media sur nas1."

# ---------------------------------------------------------------- 1. SAUVEGARDE ETCD
STAGE=1
echo; echo "=== 1. Sauvegarde etcd (sur nas2)"
k3s etcd-snapshot save --name avant-ssd1-nas1 2>&1 | grep -iE 'saved|snapshot' | tail -2

# ---------------------------------------------------------------- 2. VIDER NAS1
STAGE=2
confirm "Étape 2 : vider nas1 (drain) ? Les services media restent sur nas2." ""
kubectl drain nas1 --ignore-daemonsets --delete-emptydir-data --timeout=300s \
  || { echo "Le drain a échoué : on remet nas1 en service."; kubectl uncordon nas1; exit 1; }

# ---------------------------------------------------------------- 3. ARRÊT DE K3S
STAGE=3
confirm "Étape 3 : arrêter k3s sur nas1 ? (etcd continue avec nas2 + nas3, volumes 'degraded' le temps de l'opération)" "Pense à : kubectl uncordon nas1"
$N1 "systemctl stop k3s && /usr/local/bin/k3s-killall.sh >/dev/null 2>&1; sleep 3
     # (le containerd de Docker, /usr/bin/containerd, n'est pas concerné)
     if pgrep -f '/usr/local/bin/[k]3s' >/dev/null || pgrep -f '[r]ancher/k3s/agent/etc/containerd' >/dev/null || pgrep -f '[c]ontainerd-shim-runc-v2 -namespace k8s.io' >/dev/null; then echo 'processus k3s encore présents'; exit 1; fi
     if findmnt -rn -o TARGET | grep -q '^$OLD'; then echo 'des montages restent sous $OLD'; exit 1; fi
     echo 'k3s arrêté, plus aucun processus ni montage.'"

fi

# ---------------------------------------------------------------- 4. COPIE
STAGE=4
echo; echo "=== 4. Copie de $OLD vers $NEW (droits, liens et attributs conservés)"
$N1 "rsync -aHAX --numeric-ids $OLD/ $NEW/
     diff=\$(rsync -aHAXn --numeric-ids --delete --itemize-changes $OLD/ $NEW/ | wc -l)
     echo \"différences restantes : \$diff\"; [ \"\$diff\" = 0 ]
     echo \"taille : \$(du -sxh $OLD | cut -f1) -> \$(du -sxh $NEW | cut -f1)\""

# ---------------------------------------------------------------- 5. BASCULE
STAGE=5
confirm "Étape 5 : basculer $OLD vers $NEW (l'ancien est GARDÉ en $OLD.old) ?" "Pour relancer sans basculer : ssh nas1 systemctl start k3s, puis kubectl uncordon nas1"
$N1 "cp -p /etc/fstab /etc/fstab.avant-ssd1
     mv $OLD $OLD.old && mkdir $OLD
     echo '$FSTAB_LINE' >> /etc/fstab
     systemctl daemon-reload
     mount $OLD
     findmnt $OLD
     test -d $OLD/k3s/server/db/etcd && echo 'contenu visible au même chemin : OK'"

# ---------------------------------------------------------------- 6. REDÉMARRAGE
STAGE=6
echo; echo "=== 6. Redémarrage de k3s sur nas1"
$N1 "systemctl start k3s"
wait_nas1_ready
kubectl uncordon nas1

# ---------------------------------------------------------------- 7. CONTRÔLES
STAGE=7
echo; echo "=== 7. Contrôles"
kubectl get nodes
wait_volumes_healthy
$N1 "echo; echo '/var    :' \$(df -h --output=used,avail,pcent /var | tail -1)
     echo '/ssd1   :' \$(df -h --output=used,avail,pcent /ssd1 | tail -1)
     findmnt -n -o TARGET,SOURCE $OLD"
trap - ERR INT
echo
echo "=== Terminé. L'ancien dossier reste dans nas1:$OLD.old (retour arrière possible)."
echo "    Dans quelques jours, si tout va bien : ssh nas1 rm -rf $OLD.old"
