#!/bin/bash
# Partage NFS de /media/usb1/longhorn-backup (nas2) pour les sauvegardes Longhorn.
# Usage (sur nas2, en root) : bash /ssd1/kubernetes/longhorn-sauvegarde/activer-nfs.sh
#                             bash /ssd1/kubernetes/longhorn-sauvegarde/activer-nfs.sh --retirer
set -e
F=/etc/exports.d/longhorn-backup.exports
if [ "$1" = --retirer ]; then rm -f "$F"; exportfs -ra; echo "Partage retiré."; exit; fi
findmnt -n /media/usb1 >/dev/null || { echo "ERREUR : /media/usb1 n'est pas monté"; exit 1; }
mkdir -p /media/usb1/longhorn-backup && chmod 700 /media/usb1/longhorn-backup
cp "$(dirname "$0")/longhorn-backup.exports" "$F"
systemctl enable -q --now nfs-server
# Les erreurs d'AUTRES partages (ex. dossier disparu) ne doivent pas bloquer : on vérifie le nôtre
exportfs -ra || echo "(avertissement : erreur sur un autre partage, voir ci-dessus)"
exportfs -v | grep -q "^/media/usb1/longhorn-backup" || { echo "ERREUR : partage longhorn-backup non actif"; exit 1; }
echo "Partage actif : nfs://192.168.1.2:/media/usb1/longhorn-backup"
