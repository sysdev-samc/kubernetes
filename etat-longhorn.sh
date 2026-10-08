#!/bin/bash
# État des volumes Longhorn : santé, nœud, taille, place réellement utilisée, répliques,
# et place disque Longhorn de chaque nœud. Lecture seule.
# Usage : bash /ssd1/kubernetes/etat-longhorn.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== Volumes"
kubectl -n longhorn-system get volumes.longhorn.io -o json > /tmp/.lh-volumes.json
kubectl -n longhorn-system get replicas.longhorn.io -o json > /tmp/.lh-replicas.json
python3 - <<'PY'
import json
G = lambda b: "%.1f Go" % (int(b) / 2**30)
vols = json.load(open("/tmp/.lh-volumes.json"))["items"]
reps = json.load(open("/tmp/.lh-replicas.json"))["items"]
where = {}
for r in reps:
    where.setdefault(r["spec"]["volumeName"], []).append(
        r["spec"]["nodeID"] + ("" if r["status"].get("currentState") == "running" else "(" + r["status"].get("currentState", "?") + ")"))
print("%-26s %-9s %-9s %-8s %9s %9s  %s" % ("PVC", "ÉTAT", "SANTÉ", "ATTACHÉ", "TAILLE", "UTILISÉ", "RÉPLIQUES"))
for v in sorted(vols, key=lambda v: v["status"].get("kubernetesStatus", {}).get("pvcName", "")):
    s, st = v["spec"], v["status"]
    pvc = st.get("kubernetesStatus", {}).get("namespace", "?") + "/" + st.get("kubernetesStatus", {}).get("pvcName", "?")
    print("%-26s %-9s %-9s %-8s %9s %9s  %s" % (
        pvc.split("/", 1)[1], st["state"], st["robustness"], st.get("currentNodeID") or "-",
        G(s["size"]), G(st.get("actualSize", 0)), " ".join(sorted(where.get(v["metadata"]["name"], [])))))
PY

echo; echo "=== Disques Longhorn par nœud"
kubectl -n longhorn-system get nodes.longhorn.io -o json > /tmp/.lh-nodes.json
python3 - <<'PY'
import json
G = lambda b: "%.0f Go" % (int(b) / 2**30)
for n in json.load(open("/tmp/.lh-nodes.json"))["items"]:
    for name, d in sorted(n["status"].get("diskStatus", {}).items()):
        spec = n["spec"]["disks"].get(name, {})
        if not d.get("storageMaximum"):
            continue
        print("  %-5s %-20s max %7s  libre %7s  promis aux volumes %7s  %s" % (
            n["metadata"]["name"], d["diskPath"], G(d["storageMaximum"]), G(d["storageAvailable"]),
            G(d["storageScheduled"]), "" if spec.get("allowScheduling") else "(désactivé)"))
PY
rm -f /tmp/.lh-volumes.json /tmp/.lh-replicas.json /tmp/.lh-nodes.json
