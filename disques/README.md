# Disques : supervision et entretien (nas1, nas2, nas3)

Mis en place le 08/11/2026, après la découverte que le disque `/volume1` de nas2
(IronWolf 4 To) se dégradait **sans qu'aucune alerte ne parte** : smartd voyait le
problème mais l'envoyait par mail, et ce mail n'a jamais fonctionné.

## Ce qui tourne, et où

| | nas1 | nas2 | nas3 |
|---|---|---|---|
| smartd → Telegram | 2 SSD | SSD système + IronWolf 4 To | NVMe Crucial P2 |
| Autotest court (chaque jour, 11 h) | ✅ | ✅ | — (pas sur ce NVMe) |
| Autotest long (une fois par mois, 11 h) | le 8 et le 9 | le 1er et le 2 | — |
| TRIM hebdomadaire (`fstrim.timer`) | ✅ | ✅ | ✅ |
| e2scrub hebdomadaire (fsck en ligne, LVM) | — (pas de LVM) | `/` `/home` `/var` `/ssd1` | — (pas de LVM) |
| fsck au démarrage tous les 3 mois | toutes les partitions | `/boot` | — |
| `noatime` | `/volume1` `/ssd1` | `/volume1` `/ssd1` | déjà en place |

Non surveillés : le disque USB WD 2 To de nas2 (`/media/usb1`, retiré à la demande)
et l'eMMC système de nas3 (pas de SMART).

## Les fichiers

| Fichier (dépôt) | Installé sur le nœud | Rôle |
|---|---|---|
| `smartd.<nas>.conf` | `/etc/smartd.conf` | disques surveillés, seuils, autotests |
| `smartd-alerte.sh` | `/usr/local/sbin/smartd-alerte` | envoie l'alerte sur Telegram (bash + curl, autonome) |
| `e2scrub_fail-telegram.conf` | `/etc/systemd/system/e2scrub_fail@.service.d/telegram.conf` | erreurs e2scrub → Telegram |
| `installer-smartd.sh` | — | installe tout ce qui précède sur un nœud |
| `disques.py` | (tourne sur nas2) | état de tous les disques → carte Homepage + résumé Telegram |
| `installer-cron.sh` | `/etc/cron.d/disques` (nas2) | planifie `disques.py` |
| (`reseau/telegram.env`, hors git) | `/etc/smartd-alerte.env` (600) | jeton et canal Telegram |

## Installer, modifier, tester

```bash
# (Ré)installer sur un nœud — à lancer sur nas2, où sont le dépôt et telegram.env
bash /ssd1/kubernetes/disques/installer-smartd.sh nas1
bash /ssd1/kubernetes/disques/installer-smartd.sh nas1 --test   # + un message de test par disque

# Tester l'envoi Telegram à la main, sur un nœud
SMARTD_FAILTYPE=EmailTest SMARTD_DEVICE=/dev/sda /usr/local/sbin/smartd-alerte

# Voir les prochains autotests prévus
smartd -q showtests -c /etc/smartd.conf | grep "will do test"

# Journal de smartd et des alertes
journalctl -t smartd -t smartd-alerte --since today
```

L'installateur **valide la config avant de l'appliquer** (`smartd -q showtests`) :
si un disque ne s'ouvre pas, rien n'est changé. L'ancienne config est gardée dans
`/etc/smartd.conf.avant-telegram`.

**Ajouter ou remplacer un disque** : récupérer son identifiant stable
(`ls -l /dev/disk/by-id/`), modifier `smartd.<nas>.conf`, relancer l'installateur
avec `--test`. Ne jamais utiliser `/dev/sdX` : les noms changent (les disques iSCSI
de Longhorn s'intercalent).

## Carte Homepage « Disques » et résumé Telegram

`disques.py` lit la liste des disques **dans les `smartd.<nas>.conf` du dépôt** (une
seule source de vérité), interroge chacun avec `smartctl -j` (en local ou par SSH),
et classe son état :

- 🔴 SMART en échec, secteurs en attente / illisibles, autotest échoué, alerte NVMe,
  usure ≥ 90 %, température critique, disque injoignable ;
- 🟠 secteurs réalloués, erreurs de lecture (HDD), > 300 000 parkings de têtes,
  usure ≥ 80 %, température élevée ;
- ✅ sinon (affiche l'usure, la température, le résultat du dernier autotest).

L'eMMC de nas3 (sans SMART) est suivie par ses erreurs dans le journal du noyau (7 jours).

| Quand | Quoi |
|---|---|
| chaque heure (hh:17) | met à jour le ConfigMap `disques` → carte « Disques » (section Sécurité) |
| lundi 11 h 05 | idem + **résumé de la semaine sur Telegram** (via `reseau/surveillance.py`) |

```bash
python3 /ssd1/kubernetes/disques/disques.py                 # afficher l'état
python3 /ssd1/kubernetes/disques/disques.py --homepage      # + mettre à jour la carte
python3 /ssd1/kubernetes/disques/disques.py --telegram      # + envoyer le résumé
bash /ssd1/kubernetes/disques/installer-cron.sh             # (ré)installer la planification
```

Le cron tourne **sur nas2 seulement** (comme `surveillance.py`) : si nas2 est arrêté, la
carte n'est plus mise à jour — la ligne « 🕐 Mis à jour » le montre. Les alertes
immédiates, elles, viennent de smartd sur chaque nœud et ne dépendent pas de nas2.

## Les règles de smartd.conf (et les pièges)

- **Pas de `DEVICESCAN`** : quand cette ligne est présente, smartd **ignore toutes les
  lignes suivantes** (c'est pour ça qu'aucun autotest n'avait jamais tourné), et il
  surveille aussi les disques virtuels iSCSI de Longhorn (centaines d'erreurs).
- `-m <nomail> -M exec /usr/local/sbin/smartd-alerte` : pas de mail, script à la place.
- `-M diminishing` : tant que le problème dure, l'alerte est répétée après 1, 2, 4, 8… jours.
- `-C 197+ -U 198+` : alerte quand le nombre de secteurs en attente / illisibles
  **augmente** (pas à chaque contrôle). `-R 5!` : idem pour les secteurs réalloués.
- `-W 4,45,55` (HDD), `-W 4,60,70` (SSD), `-W 4,70,80` (NVMe) : alerte de température.
- `-s (S/../.././11|L/../01/./11)` : court chaque jour à 11 h, long le 1er du mois à 11 h.
  smartd ne lance un test qu'à ses passages (toutes les 30 min), jamais au premier
  passage après un redémarrage.
- `-n standby,q` (HDD) : ne réveille pas un disque en veille juste pour le contrôler.

## Signification des alertes

| Message Telegram | Que faire |
|---|---|
| 🔴 secteurs illisibles / 🔴 panne imminente | sauvegarder **tout de suite**, prévoir le remplacement |
| 🟠 autotest en échec / nouvelles erreurs | vérifier `smartctl -a <disque>` ; souvent le début de la fin |
| 🟠 indicateur qui se dégrade | surveiller ; si ça continue, sauvegarder |
| 🌡️ trop chaud | ventilation, poussière |
| ⚠️ SMART illisible | disque débranché, câble, ou disque mort |
| 🔴 système de fichiers endommagé (e2scrub) | `e2fsck -f` hors ligne au prochain arrêt |

Rappel : un « SMART overall-health : PASSED » **ne veut pas dire que le disque va
bien**. L'IronWolf de nas2 l'affichait avec 160 secteurs réalloués et 1 542 erreurs.
Se fier aux compteurs 5, 187, 197, 198 (et à l'usure 177/233 pour les SSD).

## e2scrub en deux mots

Fsck **en ligne** : instantané LVM du volume → `e2fsck` en lecture seule sur
l'instantané → suppression de l'instantané. Rien n'est arrêté ni démonté ; rien
n'est réparé non plus (il prévient). Ne marche **que sur LVM** (donc nas2 seulement).
Debian le livre désactivé : `periodic_e2scrub=1` dans `/etc/e2scrub.conf`.

## Disque IronWolf de nas2 (état au 08/11/2026)

En fin de vie, **à remplacer** : 160 secteurs réalloués, 16 en attente, 1 542 erreurs
de lecture, 445 000 cycles de têtes (APM 128). Mesures prises :
- APM passé à 254 (plus de parking des têtes) — règle permanente
  `/etc/udev/rules.d/69-apm-ironwolf.rules` (à adapter au numéro de série du
  disque de remplacement) ;
- exclu du fsck au démarrage (trop long sur un disque défaillant) ;
- photos sauvegardées.
