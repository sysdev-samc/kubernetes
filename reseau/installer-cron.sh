#!/bin/bash
# Installe le rapport automatique : chaque nuit à 00:05, top des envois de la VEILLE
# (journée complète), sauvé dans /ssd1/rapports-reseau/AAAA-MM-JJ.txt (+ .csv pour les moyennes).
# Usage : bash /ssd1/kubernetes/reseau/installer-cron.sh            # installer
#         bash /ssd1/kubernetes/reseau/installer-cron.sh --retirer  # désinstaller
F=/etc/cron.d/top-sortants
if [ "$1" = "--retirer" ]; then rm -f "$F" && echo "Retiré : $F"; exit; fi
cat > "$F" <<'CRON'
# Rapport quotidien des envois vers Internet (voir /ssd1/kubernetes/reseau/top-sortants.py)
5 0 * * * root /usr/bin/python3 /ssd1/kubernetes/reseau/top-sortants.py hier --sauver > /var/log/top-sortants.log 2>&1
CRON
chmod 644 "$F"
echo "Installé : $F"; cat "$F"
echo; echo "Premier rapport : demain à 00:05. Journal de la dernière exécution : /var/log/top-sortants.log"
