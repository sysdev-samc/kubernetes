# Sauvegarde et restauration des volumes Longhorn

Les configurations des services Kubernetes (radarr, sonarr, transmission, jackett, joal,
seer, speedtest…) sont dans des **volumes Longhorn**, pas dans `/ssd1/container`. Elles ne
sont donc **pas** couvertes par la copie de dossiers (`/ssd1/scripts/sauvegarde`), qui
exclut volontairement `/ssd1/longhorn` (répliques en cours d'écriture : copie incohérente).

Longhorn sait faire des sauvegardes **cohérentes** : il fige le volume (instantané) puis en
envoie une copie vers une « cible de sauvegarde ». Ici, la cible est le **disque USB de nas2**,
partagé en NFS : `nfs://192.168.1.2:/media/usb1/longhorn-backup`.

**Pas de sauvegarde automatique** (choix du 08/11/2026) : on les lance à la main.
Les sauvegardes sont incrémentales : seuls les blocs modifiés depuis la précédente sont envoyés.

## Les fichiers

| Fichier | Rôle |
|---|---|
| `activer-nfs.sh` | Partage `/media/usb1/longhorn-backup` en NFS (`--retirer` pour l'arrêter) |
| `longhorn-backup.exports` | Le partage (installé dans `/etc/exports.d/`) : LAN + pods, actif **seulement si l'USB est monté** (`mp=`) |
| `configurer.sh` | Branche Longhorn sur ce partage (une fois pour toutes) |
| `sauvegarder-maintenant.sh` | Sauvegarde tous les volumes, ou ceux qu'on lui donne |
| `restaurer-volume.sh` | Liste les sauvegardes ; restaure un PVC |

## Installation (une seule fois)

```bash
# disque USB monté sur /media/usb1, puis :
bash /ssd1/kubernetes/longhorn-sauvegarde/activer-nfs.sh
bash /ssd1/kubernetes/longhorn-sauvegarde/configurer.sh
```

## Faire une sauvegarde (à la main)

```bash
mount /dev/disk/by-uuid/9660d280-3027-4aea-8922-a8021b7f8938 /media/usb1   # si l'USB n'est pas monté
bash /ssd1/kubernetes/longhorn-sauvegarde/activer-nfs.sh                    # si le partage n'est pas actif
bash /ssd1/kubernetes/longhorn-sauvegarde/sauvegarder-maintenant.sh         # TOUS les volumes
bash /ssd1/kubernetes/longhorn-sauvegarde/sauvegarder-maintenant.sh radarr-config sonarr-config   # ou quelques-uns
```

Chaque volume est figé puis copié ; le script attend la fin et affiche `Completed` (ou
`Error`) pour chacun. Le **nom du PVC et son namespace sont enregistrés dans la sauvegarde**
(sur l'USB) : c'est ce qui permet de tout reconstruire même si le cluster a disparu. Les services **continuent de tourner** pendant la sauvegarde.

**Démonter l'USB proprement** : `activer-nfs.sh --retirer`, puis `umount /media/usb1`
(sinon le démontage échoue : « target is busy »).

Si l'USB n'est pas monté, le partage n'existe pas : la sauvegarde échoue proprement
(« cible de sauvegarde indisponible ») et **rien n'est écrit sur le disque système**.

**Faire de la place** : les sauvegardes ne sont jamais supprimées automatiquement.
`bash restaurer-volume.sh --liste` pour les voir, puis
`kubectl -n longhorn-system delete backups.longhorn.io <nom>` pour en supprimer une
(ou interface Longhorn → Backup).

## Restaurer un volume

Procédure **testée le 08/11/2026** sur un volume jetable : restauration (fichiers identiques
à l'octet près), retour en arrière, et reconstruction après suppression complète
(namespace, PVC, PV et volume). Durée : environ 1 minute pour un petit volume.

```bash
cd /ssd1/kubernetes/longhorn-sauvegarde
bash restaurer-volume.sh --liste                       # toutes les sauvegardes
bash restaurer-volume.sh --liste radarr-config         # celles d'un PVC
bash restaurer-volume.sh radarr-config                 # restaure la DERNIÈRE (demande confirmation)
bash restaurer-volume.sh radarr-config <nom>           # restaure une sauvegarde précise
bash restaurer-volume.sh -n autre-namespace mon-pvc    # autre namespace que media
```

Ce que fait le script, dans cet ordre (le service n'est coupé qu'à l'étape 2) :

1. **crée un nouveau volume** à partir de la sauvegarde, pendant que le service tourne encore ;
   si ça échoue, rien n'a été touché ;
2. **arrête** les déploiements qui utilisent le PVC (ex. pour `jackett-config`, `joal-data`,
   `transmission-config` : tout le pod transmission, donc transmission + joal + jackett) ;
3. **détache l'ancien volume sans le supprimer** (son PV passe en `Retain`, copie du PVC dans
   `/tmp/<pvc>.pvc-avant-restauration.json`) ;
4. **recrée le PVC** sous le même nom, branché sur le volume restauré ;
5. **redémarre** les déploiements.

### Après la restauration

Vérifier le service. Si tout va bien, **supprimer l'ancien volume** (le script affiche la
commande exacte) — sinon `bascule-kubernetes.sh` refusera de basculer (volume détaché) :

```bash
kubectl delete pv <ancien-pv> && kubectl -n longhorn-system delete volumes.longhorn.io <ancien-pv>
```

### Revenir en arrière (si la sauvegarde restaurée ne convient pas)

L'ancien volume est intact tant qu'on ne l'a pas supprimé :

```bash
kubectl -n media scale deploy <deploiement> --replicas=0
kubectl -n media delete pvc <pvc>                                   # libère le volume restauré
kubectl patch pv <ancien-pv> --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl apply -f /tmp/<pvc>.pvc-avant-restauration.json             # PVC d'origine -> ancien volume
kubectl -n media scale deploy <deploiement> --replicas=1
kubectl delete pv <volume-restauré>                                 # puis supprimer le volume restauré
kubectl -n longhorn-system delete volumes.longhorn.io <volume-restauré>
```

### Tout reconstruire (perte du cluster ou de Longhorn)

1. Réinstaller k3s et Longhorn, remonter l'USB, `activer-nfs.sh`, `configurer.sh` :
   Longhorn relit alors toutes les sauvegardes présentes sur le disque USB.
2. Pour chaque PVC (voir `restaurer-volume.sh --liste`) : `bash restaurer-volume.sh <pvc> --oui`.
   Le PVC n'existant plus, il est simplement **créé** à partir de la sauvegarde.
3. Appliquer ensuite les déploiements et services (`kubectl apply -f /ssd1/kubernetes/<service>/03-deployment.yaml`
   et `04-service.yaml`, **pas** tout le dossier : il contient d'anciens pods de migration) : ils retrouvent leurs PVC.
