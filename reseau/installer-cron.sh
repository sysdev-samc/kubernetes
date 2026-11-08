#!/bin/bash
# Installe le rapport automatique : chaque nuit à 00:05, top des envois de la VEILLE
# (journée complète), sauvé dans /ssd1/rapports-reseau/AAAA-MM-JJ.txt (+ .csv pour les moyennes).
# + toutes les heures (à hh:07) : mise à jour de la carte "Top envois" de Homepage (journée en cours).
# + toutes les 5 minutes : surveillance de sécurité (surveillance.py) -> alertes iPhone + cartes Sécurité.
# Usage : bash /ssd1/kubernetes/reseau/installer-cron.sh            # installer
#         bash /ssd1/kubernetes/reseau/installer-cron.sh --retirer  # désinstaller
F=/etc/cron.d/top-sortants
R=/etc/logrotate.d/surveillance-reseau
if [ "$1" = "--retirer" ]; then rm -f "$F" "$R" && echo "Retiré : $F $R"; exit; fi
cat > "$F" <<'CRON'
# Rapport quotidien des envois vers Internet (voir /ssd1/kubernetes/reseau/top-sortants.py)
5 0 * * * root /usr/bin/python3 /ssd1/kubernetes/reseau/top-sortants.py hier --sauver > /var/log/top-sortants.log 2>&1
7 * * * * root /usr/bin/python3 /ssd1/kubernetes/reseau/top-sortants.py aujourdhui --homepage > /var/log/top-sortants-homepage.log 2>&1
# Surveillance de sécurité (voir /ssd1/kubernetes/reseau/surveillance.py)
*/5 * * * * root /usr/bin/python3 /ssd1/kubernetes/reseau/surveillance.py >> /var/log/surveillance-reseau.log 2>&1
CRON
chmod 644 "$F"
cat > "$R" <<'ROT'
/var/log/surveillance-reseau.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
ROT
echo "Installé : $F"; cat "$F"
echo; echo "Premier rapport : demain à 00:05. Journal de la dernière exécution : /var/log/top-sortants.log"
