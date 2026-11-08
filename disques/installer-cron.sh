#!/bin/bash
# Planifie disques.py sur nas2 : carte Homepage "Disques" chaque heure (hh:17),
# + résumé Telegram chaque lundi à 11 h 05.
# Usage : bash /ssd1/kubernetes/disques/installer-cron.sh            # installer
#         bash /ssd1/kubernetes/disques/installer-cron.sh --retirer  # désinstaller
F=/etc/cron.d/disques
if [ "$1" = "--retirer" ]; then rm -f "$F" && echo "Retiré : $F"; exit; fi
cat > "$F" <<'CRON'
# État des disques des 3 NAS (voir /ssd1/kubernetes/disques/README.md)
17 * * * 1-7 root /usr/bin/python3 /ssd1/kubernetes/disques/disques.py --homepage > /var/log/disques.log 2>&1
5 11 * * 1   root /usr/bin/python3 /ssd1/kubernetes/disques/disques.py --homepage --telegram > /var/log/disques-telegram.log 2>&1
CRON
chmod 644 "$F"
echo "Installé : $F"; grep -v "^#" "$F"
