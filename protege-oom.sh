#!/bin/bash
# PROTECTION DU STOCKAGE CONTRE L'OOM KILLER (manque de RAM).
# Kubernetes donne aux pods Longhorn (sans "requests") un oom_score_adj de 1000 : ce sont
# les PREMIERS tués quand la RAM manque (incident du 05/11/2026 sur nas2 : longhorn-manager
# tué, volumes perdus, bascule de tous les pods). Ce script baisse leur score à -900 :
# le noyau tue d'abord les pods media (~984) et les conteneurs Docker non essentiels (1000).
# Les processus créés ensuite (moteurs/répliques Longhorn) héritent du score de leur parent ;
# le timer repasse chaque minute pour les pods (re)créés entre-temps.
#
# Usage : bash /ssd1/kubernetes/protege-oom.sh               # applique une fois (affiche les changements)
#         bash /ssd1/kubernetes/protege-oom.sh --installer   # service + timer systemd (chaque minute)
#         bash /ssd1/kubernetes/protege-oom.sh --etat        # scores actuels
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SCORE=-900
NS="longhorn-system"
NODE=$(hostname -s)

if [ "$1" = --installer ]; then
  cat > /etc/systemd/system/protege-oom.service <<EOF
[Unit]
Description=Protège Longhorn de l'OOM killer (oom_score_adj $SCORE)
After=k3s.service
[Service]
Type=oneshot
ExecStart=/bin/bash $(readlink -f "$0")
EOF
  cat > /etc/systemd/system/protege-oom.timer <<'EOF'
[Unit]
Description=Protège Longhorn de l'OOM killer (chaque minute)
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && systemctl enable --now protege-oom.timer
  systemctl list-timers protege-oom.timer --no-pager; exit
fi

# UID des pods Longhorn de ce nœud, au format des cgroups systemd (tirets -> soulignés)
uids=$(kubectl -n $NS get pods --field-selector spec.nodeName=$NODE -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' | tr - _)
[ -n "$uids" ] || { echo "aucun pod $NS sur $NODE (API injoignable ?)"; exit 1; }
motif=$(echo "$uids" | sed 's/^/pod/' | paste -sd'|')

for d in /proc/[0-9]*; do
  grep -qE "$motif" "$d/cgroup" 2>/dev/null || continue
  adj=$(cat "$d/oom_score_adj" 2>/dev/null) || continue
  if [ "$1" = --etat ]; then
    echo "$adj $(cat "$d/comm")"
  elif [ "$adj" -gt "$SCORE" ]; then     # ne remonte jamais un score plus bas (ex. tgtd à -1000)
    echo "$SCORE" > "$d/oom_score_adj" 2>/dev/null && echo "${d#/proc/} $(cat "$d/comm") : $adj -> $SCORE"
  fi
done | { [ "$1" = --etat ] && sort | uniq -c || cat; }
