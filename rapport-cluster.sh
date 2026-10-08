#!/bin/bash
# RAPPORT DE DIAGNOSTIC DU CLUSTER (lecture seule : ne modifie rien).
# Croise ce que sait Kubernetes (état actuel, événements de la dernière heure environ)
# et les journaux système des NAS (manques de mémoire, redémarrages de k3s : plusieurs jours).
#
# Usage : bash /ssd1/kubernetes/rapport-cluster.sh            # affiche le rapport (incidents sur 24 h)
#         bash /ssd1/kubernetes/rapport-cluster.sh 72          # incidents sur les 72 dernières heures
#         bash /ssd1/kubernetes/rapport-cluster.sh 24 --sauver # + copie dans /ssd1/rapports-cluster/
HEURES=${1:-24}
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NODES_SSH="nas1 nas2"           # nœuds dont on lit les journaux (nas3 : pas d'accès SSH)
NS=media
SORTIE=/ssd1/rapports-cluster

on_node() { if [ "$1" = "$(hostname -s)" ]; then bash -c "$2"; else ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" "$2" 2>/dev/null || echo "  (nœud $1 injoignable)"; fi; }
titre()   { echo; echo "=================================================================="; echo "  $*"; echo "=================================================================="; }

rapport() {
echo "RAPPORT DU CLUSTER  —  $(date '+%A %d %B %Y, %H:%M:%S')  —  incidents sur ${HEURES} h"

# ------------------------------------------------------------------------------------------
titre "1. NŒUDS"
kubectl get nodes -o json | python3 -c '
import json,sys
from datetime import datetime,timezone
now=datetime.now(timezone.utc)
print("  %-5s %-9s %-19s %-22s %s" % ("NŒUD","ÉTAT","ÉTAT DEPUIS","MARQUES / INTERDIT","ALERTES"))
for n in json.load(sys.stdin)["items"]:
    c={x["type"]:x for x in n["status"]["conditions"]}
    r=c.get("Ready",{}); since=datetime.fromisoformat(r.get("lastTransitionTime","").replace("Z","+00:00"))
    d=now-since; age=("%dj %dh" % (d.days,d.seconds//3600)) if d.days else ("%dh %dmin" % (d.seconds//3600,(d.seconds%3600)//60))
    alerts=[t for t in ("MemoryPressure","DiskPressure","PIDPressure") if c.get(t,{}).get("status")=="True"]
    taints=[t["key"].split("/")[-1] for t in n["spec"].get("taints",[])]
    print("  %-5s %-9s %-19s %-22s %s" % (n["metadata"]["name"], "Ready" if r.get("status")=="True" else "NOT-READY",
          age, ",".join(taints) or "-", ",".join(alerts) or "-"))'
echo; echo "  etcd : $(kubectl get --raw '/readyz?verbose' 2>/dev/null | grep -E '^\[.\]etcd ' | tr '\n' ' ')"
echo "  IP 192.168.1.150 annoncée par : $(kubectl -n $NS get events --field-selector reason=nodeAssigned --sort-by=.lastTimestamp -o jsonpath='{.items[-1:].message}' 2>/dev/null | grep -oE 'node "[^"]+"' || echo '?')"

# ------------------------------------------------------------------------------------------
titre "2. RESSOURCES (CPU, mémoire, disques)"
echo "  --- vu par Kubernetes"
kubectl top nodes 2>/dev/null | sed 's/^/  /'
for n in $NODES_SSH; do
  echo; echo "  --- $n"
  on_node $n '
    echo "  démarré depuis : $(uptime -p | sed "s/up //")  |  charge 1/5/15 min : $(cut -d" " -f1-3 /proc/loadavg)  |  k3s actif depuis : $(systemctl show k3s -p ActiveEnterTimestamp --value | cut -d" " -f2-3)"
    free -m | awk "/Mem:/{printf \"  mémoire : %d / %d Mo utilisés (%d%%), %d Mo disponibles\n\", \$3, \$2, \$3*100/\$2, \$7} /Swap:/{printf \"  swap    : %d / %d Mo\n\", \$3, \$2}"
    df -h --output=target,size,used,avail,pcent / /var /ssd1 /var/lib/rancher /volume1 2>/dev/null | awk "NR==1{print \"  \" \$0; next} !seen[\$1]++{print \"  \" \$0}"
    echo "  plus gros consommateurs de mémoire :"
    ps -eo rss,args --sort=-rss | awk "NR>1 && NR<=7{r=\$1; \$1=\"\"; printf \"    %6d Mo %s\n\", r/1024, substr(\$0,1,60)}"
    if command -v docker >/dev/null; then
      echo "  conteneurs Docker (mémoire) :"
      docker stats --no-stream --format "{{.MemPerc}}|{{.MemUsage}}|{{.Name}}" 2>/dev/null | sort -t"|" -k1 -g -r | head -5 | awk -F"|" "{split(\$2,u,\" / \"); printf \"    %-10s %s\n\", u[1], \$3}"
      docker ps --format "{{.Names}} {{.Status}}" | grep -iE "restarting|unhealthy" | sed "s/^/    ATTENTION : /"
    fi'
done

# ------------------------------------------------------------------------------------------
titre "3. INCIDENTS SYSTÈME (journaux des NAS, ${HEURES} dernières heures)"
for n in $NODES_SSH; do
  echo "  --- $n"
  on_node $n "
    boots=\$(journalctl --list-boots --no-pager 2>/dev/null | awk -v s=\$(date -d '-${HEURES} hours' +%s) 'NR>1 && \$4 ~ /^[0-9]/ {cmd=\"date -d \\\"\"\$4\" \"\$5\"\\\" +%s\"; cmd | getline t; close(cmd); if (t>=s) print \"    redémarrage de la machine : \"\$4\" \"\$5}')
    [ -n \"\$boots\" ] && echo \"\$boots\"
    journalctl -k --since '-${HEURES} hours' --no-pager -o short-iso 2>/dev/null | grep -E 'Out of memory: Killed process' \
      | sed -E 's/^([0-9T:-]+).*Killed process [0-9]+ \(([^)]+)\).*/    MANQUE DE MÉMOIRE \1 : processus tué = \2/' | uniq | tail -15
    journalctl -u k3s --since '-${HEURES} hours' --no-pager -o short-iso 2>/dev/null | grep -E 'Started k3s.service' \
      | sed -E 's/^([0-9T:-]+).*/    k3s (re)démarré : \1/' | tail -10
    journalctl -u k3s --since '-${HEURES} hours' --no-pager -o short-iso 2>/dev/null | grep -cE 'leader changed|elected leader' | sed 's/^/    changements de leader etcd : /'
  " | grep . || echo "    rien à signaler"
done

# ------------------------------------------------------------------------------------------
titre "4. SERVICES ($NS) : où tournent-ils ?"
kubectl -n $NS get pods -o json | python3 -c '
import json,sys
from datetime import datetime,timezone
now=datetime.now(timezone.utc)
print("  %-34s %-6s %-12s %-6s %-9s %s" % ("POD","PRÊT","ÉTAT","NŒUD","REDÉM.","ÂGE"))
for p in sorted(json.load(sys.stdin)["items"], key=lambda p:p["metadata"]["name"]):
    cs=p["status"].get("containerStatuses",[])
    ready=sum(1 for c in cs if c.get("ready")); restarts=sum(c.get("restartCount",0) for c in cs)
    st=p["status"].get("phase","?")
    for c in cs:
        w=c.get("state",{}).get("waiting")
        if w: st=w.get("reason",st)
    t=datetime.fromisoformat(p["metadata"]["creationTimestamp"].replace("Z","+00:00")); d=now-t
    age=("%dj %dh" % (d.days,d.seconds//3600)) if d.days else ("%dh %dmin" % (d.seconds//3600,(d.seconds%3600)//60))
    last=[c.get("lastState",{}).get("terminated",{}).get("reason") for c in cs]
    last=[x for x in last if x]
    print("  %-34s %-6s %-12s %-6s %-9s %s %s" % (p["metadata"]["name"][:34], "%d/%d"%(ready,len(cs)), st[:12],
          p["spec"].get("nodeName","-"), restarts, age, ("(dernier arrêt : "+",".join(last)+")") if last else ""))'
echo "  Répartition : $(for n in nas1 nas2 nas3; do printf '%s=%s ' $n "$(kubectl -n $NS get pods --field-selector spec.nodeName=$n --no-headers 2>/dev/null | wc -l)"; done)"

# ------------------------------------------------------------------------------------------
titre "5. ÉVÉNEMENTS KUBERNETES IMPORTANTS (environ la dernière heure)"
kubectl get events -A --sort-by=.lastTimestamp -o json | python3 -c '
import json,sys
KEEP={"NodeNotReady","NodeReady","TaintManagerEviction","Evicted","Killing","OOMKilling","FailedScheduling",
      "FailedAttachVolume","FailedMount","BackOff","Unhealthy","NodeHasDiskPressure","NodeHasInsufficientMemory",
      "RegisteredNode","Rebooted","Starting","SystemOOM"}
ev=[e for e in json.load(sys.stdin)["items"] if e.get("reason") in KEEP or e.get("type")=="Warning"]
if not ev: print("  aucun")
for e in ev[-25:]:
    o=e["involvedObject"]; ts=(e.get("lastTimestamp") or e.get("eventTime") or "")
    from datetime import datetime
    t=datetime.fromisoformat(ts.replace("Z","+00:00")).astimezone().strftime("%H:%M:%S") if ts else "--:--:--"
    print("  %s %-24s %-28s x%-3s %s" % (t, e["reason"][:24], (o["kind"][:4]+"/"+o["name"])[:28], e.get("count",1), e.get("message","")[:70].replace("\n"," ")))'

# ------------------------------------------------------------------------------------------
titre "6. STOCKAGE LONGHORN"
bash "$(dirname "$0")/etat-longhorn.sh" 2>/dev/null | sed 's/^/  /'
}

if [ "$2" = "--sauver" ]; then
  mkdir -p "$SORTIE"; f="$SORTIE/rapport-$(date +%Y%m%d-%H%M).txt"
  rapport 2>&1 | tee "$f"; echo; echo "Rapport sauvé dans $f"
else
  rapport 2>&1
fi
