#!/bin/bash
# RESTAURATION d'un volume (PVC) depuis une sauvegarde Longhorn.
#
# Usage :
#   bash restaurer-volume.sh --liste [PVC]               # sauvegardes disponibles (toutes, ou d'un PVC)
#   bash restaurer-volume.sh PVC                         # restaure la DERNIÈRE sauvegarde du PVC
#   bash restaurer-volume.sh PVC NOM-DE-SAUVEGARDE       # restaure une sauvegarde précise (voir --liste)
#   options : -n NAMESPACE (défaut : media)   --oui (pas de question de confirmation)
#
# Déroulement :
#   1. crée un NOUVEAU volume Longhorn à partir de la sauvegarde (l'ancien n'est pas touché) ;
#   2. arrête les déploiements qui utilisent le PVC ;
#   3. détache l'ancien volume du PVC SANS le supprimer (PV passé en "Retain") ;
#   4. recrée le PVC, même nom, branché sur le volume restauré ;
#   5. redémarre les déploiements.
# Fonctionne aussi si le PVC n'existe plus (cluster réinstallé, namespace supprimé...) :
# le PVC est alors simplement créé à partir de la sauvegarde.
# L'ancien volume reste disponible pour revenir en arrière (commandes affichées à la fin).
set -e -o pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=media; OUI=0; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -n) NS=$2; shift 2 ;;
    --oui) OUI=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
LH="kubectl -n longhorn-system"

# Sauvegardes terminées, avec le PVC d'origine (lu dans les métadonnées Kubernetes de la sauvegarde)
# Sortie : nom|date|namespace|pvc|volume|taille_volume|url   (plus récentes en premier)
# PVC d'origine : 1) étiquettes posées par sauvegarder-maintenant.sh (dans la sauvegarde) ;
# 2) étiquette KubernetesStatus de Longhorn ; 3) PVC actuel qui utilise ce volume.
sauvegardes() {
  kubectl get pvc -A -o jsonpath='{range .items[*]}{.spec.volumeName} {.metadata.namespace} {.metadata.name}{"\n"}{end}' > /tmp/.pvc-actuels.$$
  $LH get backups.longhorn.io -o json | python3 -c '
import json, sys
actuels = {l.split()[0]: l.split()[1:] for l in open(sys.argv[1]) if len(l.split()) == 3}
for b in json.load(sys.stdin)["items"]:
    s = b.get("status", {})
    if s.get("state") != "Completed": continue
    lab = s.get("labels") or {}
    ns, pvc = lab.get("sauvegarde/namespace"), lab.get("sauvegarde/pvc")
    if not pvc:
        try: k = json.loads(lab.get("KubernetesStatus", "{}")); ns, pvc = k.get("namespace"), k.get("pvcName")
        except Exception: pass
    if not pvc: ns, pvc = actuels.get(s.get("volumeName", ""), ["?", "?"])
    print("|".join([b["metadata"]["name"], s.get("backupCreatedAt", ""), ns or "?", pvc or "?",
                    s.get("volumeName", ""), s.get("volumeSize", "0"), s.get("url", "")]))' /tmp/.pvc-actuels.$$ | sort -t'|' -k2 -r
  rm -f /tmp/.pvc-actuels.$$
}

if [ "${ARGS[0]}" = --liste ]; then
  printf '%-40s %-22s %-28s %s\n' SAUVEGARDE DATE PVC VOLUME
  sauvegardes | while IFS='|' read -r n d ns p v t u; do
    [ -n "${ARGS[1]}" ] && [ "$p" != "${ARGS[1]}" ] && continue
    printf '%-40s %-22s %-28s %s\n' "$n" "${d%.*}" "$ns/$p" "$v ($(numfmt --to=iec "$t"))"
  done; exit 0
fi
PVC=${ARGS[0]}; CHOIX=${ARGS[1]}
[ -n "$PVC" ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# --- 1. Choix de la sauvegarde --------------------------------------------------------------
ligne=$(sauvegardes | awk -F'|' -v p="$PVC" -v ns="$NS" -v c="$CHOIX" '$4==p && $3==ns && (c=="" || $1==c)' | head -1)
[ -n "$ligne" ] || { echo "ERREUR : aucune sauvegarde terminée pour $NS/$PVC${CHOIX:+ nommée $CHOIX} (voir --liste)"; exit 1; }
IFS='|' read -r BK DATE _ _ VOL_ORIG TAILLE URL <<< "$ligne"
NOUVEAU="$(echo "$PVC" | cut -c1-30)-restaure-$(date +%Y%m%d-%H%M)"
ANCIEN_PV=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
DEPLOIS=$(kubectl -n "$NS" get deploy -o json 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin)["items"]:
    vols = d["spec"]["template"]["spec"].get("volumes", [])
    if any(v.get("persistentVolumeClaim", {}).get("claimName") == sys.argv[1] for v in vols):
        print(d["metadata"]["name"], d["spec"].get("replicas", 1))' "$PVC" || true)

echo "Restauration de $NS/$PVC"
echo "  sauvegarde : $BK du ${DATE%.*} ($(numfmt --to=iec "$TAILLE"))"
echo "  nouveau volume : $NOUVEAU"
SANS_PVC="(aucun : le PVC n'existe pas, il sera créé)"   # dans ${...:-}, une apostrophe casserait la ligne
echo "  ancien volume  : ${ANCIEN_PV:-$SANS_PVC}"
echo "  déploiements arrêtés pendant l'opération : ${DEPLOIS:-(aucun)}" | tr '\n' ' '; echo
if [ $OUI = 0 ]; then read -r -p "Continuer ? [o/N] " r; [ "$r" = o ] || exit 1; fi

# --- 2. Nouveau volume Longhorn depuis la sauvegarde (rien n'est encore arrêté) --------------
echo "=== Restauration des données dans $NOUVEAU (peut prendre plusieurs minutes)"
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata: { name: $NOUVEAU, namespace: longhorn-system }
spec:
  fromBackup: "$URL"
  size: "$TAILLE"
  numberOfReplicas: 2
  frontend: blockdev
  accessMode: rwo
  dataEngine: v1
  backupTargetName: default
EOF
sleep 10
for i in $(seq 1 360); do
  etat=$($LH get volumes.longhorn.io "$NOUVEAU" -o jsonpath='{.status.state}/{.status.restoreRequired}')
  [ "$etat" = "detached/false" ] && break; sleep 5
done
[ "$etat" = "detached/false" ] || { echo "ERREUR : restauration non terminée ($etat). Rien n'a été arrêté ni modifié."; exit 1; }
echo "données restaurées"

# --- 3. Arrêt des déploiements, détachement de l'ancien volume -------------------------------
while read -r d n; do [ -n "$d" ] && kubectl -n "$NS" scale deploy "$d" --replicas=0; done <<< "$DEPLOIS"
while read -r d n; do [ -n "$d" ] && kubectl -n "$NS" wait --for=delete pod -l "app=$d" --timeout=180s 2>/dev/null || true; done <<< "$DEPLOIS"
if [ -n "$ANCIEN_PV" ]; then
  kubectl patch pv "$ANCIEN_PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
  # Copie "propre" de l'ancien PVC (recréable tel quel pour revenir en arrière)
  kubectl -n "$NS" get pvc "$PVC" -o json | python3 -c '
import json, sys
p = json.load(sys.stdin); m = p["metadata"]
for k in ("uid", "resourceVersion", "creationTimestamp", "managedFields", "finalizers"): m.pop(k, None)
m["annotations"] = {k: v for k, v in m.get("annotations", {}).items() if not k.startswith(("pv.kubernetes.io/", "volume.", "kubectl.kubernetes.io/"))}
p.pop("status", None)
json.dump(p, sys.stdout, indent=1)' > "/tmp/$PVC.pvc-avant-restauration.json"
  kubectl -n "$NS" delete pvc "$PVC" --wait=true
fi

# --- 4. PV + PVC (même nom) sur le volume restauré --------------------------------------------
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $NOUVEAU
  # Confie le volume au pilote Longhorn : supprimer ce PV (ou son PVC) supprimera aussi le volume
  annotations: { pv.kubernetes.io/provisioned-by: driver.longhorn.io }
spec:
  capacity: { storage: "$TAILLE" }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Delete
  storageClassName: longhorn
  volumeMode: Filesystem
  claimRef: { namespace: $NS, name: $PVC }
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: $NOUVEAU
    volumeAttributes: { numberOfReplicas: "2", staleReplicaTimeout: "30", dataEngine: v1 }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $PVC, namespace: $NS }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  volumeName: $NOUVEAU
  resources: { requests: { storage: "$TAILLE" } }
EOF
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound pvc/"$PVC" --timeout=120s

# --- 5. Redémarrage ---------------------------------------------------------------------------
while read -r d n; do
  [ -n "$d" ] || continue
  kubectl -n "$NS" scale deploy "$d" --replicas="$n"
  kubectl -n "$NS" rollout status deploy "$d" --timeout=420s
done <<< "$DEPLOIS"

echo
echo "=== Restauration terminée : $NS/$PVC utilise maintenant $NOUVEAU (sauvegarde $BK)."
if [ -n "$ANCIEN_PV" ]; then
  echo "L'ANCIEN volume $ANCIEN_PV est conservé (PV en 'Released')."
  echo "  Vérifie le service. Si tout va bien, supprime l'ancien volume (sinon la bascule nas1/nas2 refuse) :"
  echo "    kubectl delete pv $ANCIEN_PV && kubectl -n longhorn-system delete volumes.longhorn.io $ANCIEN_PV"
  echo "  Pour REVENIR à l'ancien volume : voir 'Revenir en arrière' dans README.md"
  echo "  (copie de l'ancien PVC : /tmp/$PVC.pvc-avant-restauration.json)"
fi
