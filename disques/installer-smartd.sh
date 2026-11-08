#!/bin/bash
# Installe la supervision et l'entretien des disques sur un nœud : nas1, nas2 ou nas3.
#   - smartd -> Telegram (autotests à 11 h)
#   - TRIM hebdomadaire (fstrim.timer) et e2scrub hebdomadaire des volumes LVM (erreurs -> Telegram)
# À lancer sur nas2 (là où sont le dépôt et reseau/telegram.env) :
#   bash /ssd1/kubernetes/disques/installer-smartd.sh nas3
#   bash /ssd1/kubernetes/disques/installer-smartd.sh nas3 --test   # + envoie un message de test par disque
# Copie : smartd-alerte.sh -> /usr/local/sbin/smartd-alerte, smartd.<nœud>.conf -> /etc/smartd.conf
# (ancienne config sauvegardée), jeton Telegram -> /etc/smartd-alerte.env (600). Valide la config
# AVANT de redémarrer smartd ; en cas d'erreur, l'ancienne config est remise.
set -e -o pipefail
NODE=$1; TEST=$2
ICI=$(cd "$(dirname "$0")" && pwd)
case "$NODE" in nas1|nas2|nas3) ;; *) sed -n 2,7p "$0"; exit 1 ;; esac
[ -f "$ICI/smartd.$NODE.conf" ] || { echo "ERREUR : $ICI/smartd.$NODE.conf absent"; exit 1; }
TG="$ICI/../reseau/telegram.env"
[ -f "$TG" ] || { echo "ERREUR : $TG absent"; exit 1; }
run() { if [ "$NODE" = "$(hostname -s)" ]; then bash -c "$1"; else ssh -o BatchMode=yes "$NODE" "$1"; fi; }
put() { if [ "$NODE" = "$(hostname -s)" ]; then cat > "$1"; else ssh -o BatchMode=yes "$NODE" "cat > '$1'"; fi; }

echo "=== $NODE : smartmontools"
run 'command -v smartctl >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq smartmontools curl >/dev/null; }; smartctl --version | head -1'

echo "=== $NODE : script d'alerte et jeton Telegram"
put /usr/local/sbin/smartd-alerte < "$ICI/smartd-alerte.sh"
grep -E '^TELEGRAM_(BOT_TOKEN|CHAT_ID)=' "$TG" | put /etc/smartd-alerte.env
run 'chmod 755 /usr/local/sbin/smartd-alerte; chmod 600 /etc/smartd-alerte.env; chown root:root /etc/smartd-alerte.env'

echo "=== $NODE : configuration smartd"
put /etc/smartd.conf.nouveau < "$ICI/smartd.$NODE.conf"
run 'set -e
  [ -f /etc/smartd.conf.avant-telegram ] || cp -p /etc/smartd.conf /etc/smartd.conf.avant-telegram 2>/dev/null || true
  # Validation (sans alerte) : syntaxe + chaque disque doit s ouvrir avec ses options
  if ! smartd -q showtests -c /etc/smartd.conf.nouveau >/tmp/smartd-check.log 2>&1; then
    tail -15 /tmp/smartd-check.log; rm /etc/smartd.conf.nouveau; echo "ERREUR : config refusée, rien changé"; exit 1
  fi
  grep -E "is SMART capable|Monitoring|NVMe" /tmp/smartd-check.log | grep -v "^$" | sed "s/^/  /" | head -8
  mv /etc/smartd.conf.nouveau /etc/smartd.conf
  systemctl enable -q smartmontools 2>/dev/null || systemctl enable -q smartd
  systemctl restart smartmontools 2>/dev/null || systemctl restart smartd
  sleep 3
  echo "smartd : $(systemctl is-active smartmontools 2>/dev/null || systemctl is-active smartd)"
  echo "autotests planifiés :"; smartd -q showtests -c /etc/smartd.conf 2>/dev/null | grep -E "Device:.*will do test" | sort -u -k2,2 | head -6 | sed "s/^/  /"'

echo "=== $NODE : TRIM et e2scrub"
run 'mkdir -p /etc/systemd/system/e2scrub_fail@.service.d'
put /etc/systemd/system/e2scrub_fail@.service.d/telegram.conf < "$ICI/e2scrub_fail-telegram.conf"
run 'set -e
  sed -i "s|^# periodic_e2scrub=1\$|periodic_e2scrub=1|" /etc/e2scrub.conf 2>/dev/null || true
  systemctl daemon-reload; systemctl enable -q --now fstrim.timer e2scrub_all.timer
  echo "fstrim.timer : $(systemctl is-enabled fstrim.timer) | e2scrub : $(grep -c "^periodic_e2scrub=1" /etc/e2scrub.conf 2>/dev/null) | volumes LVM : $(lvs --noheadings 2>/dev/null | wc -l)"'

if [ "$TEST" = --test ]; then
  echo "=== $NODE : message de test (1 par disque)"
  run "awk '!/^#/ && /^\\/dev/ {print \$1}' /etc/smartd.conf | while read d; do SMARTD_FAILTYPE=EmailTest SMARTD_DEVICE=\$d SMARTD_DEVICEINFO=\"\$(basename \$d)\" /usr/local/sbin/smartd-alerte && echo \"  envoyé : \$(basename \$d)\"; done"
fi
