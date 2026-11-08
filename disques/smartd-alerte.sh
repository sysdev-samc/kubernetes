#!/bin/bash
# Appelé par smartd (directive "-M exec") quand un disque pose problème -> message Telegram.
# Installé dans /usr/local/sbin/smartd-alerte par installer-smartd.sh. Autonome (bash + curl) :
# fonctionne aussi sur nas3, qui n'a pas le dépôt.
# Jeton et canal : /etc/smartd-alerte.env (droits 600, copie de reseau/telegram.env, hors git).
# Variables fournies par smartd : SMARTD_DEVICE, SMARTD_DEVICEINFO, SMARTD_FAILTYPE,
#   SMARTD_MESSAGE, SMARTD_TFIRST (voir "man smartd.conf", directive -M exec).
# Test à la main : SMARTD_FAILTYPE=EmailTest SMARTD_DEVICE=/dev/sda smartd-alerte
ENV=/etc/smartd-alerte.env
[ -r "$ENV" ] || { logger -t smartd-alerte "ERREUR : $ENV absent"; exit 1; }
TELEGRAM_BOT_TOKEN=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV")
TELEGRAM_CHAT_ID=$(sed -n 's/^TELEGRAM_CHAT_ID=//p' "$ENV")

case "$SMARTD_FAILTYPE" in
  EmailTest)       titre="🧪 Test des alertes disques" ;;
  Health)          titre="🔴 DISQUE EN PANNE IMMINENTE (SMART FAILED)" ;;
  CurrentPendingSector|OfflineUncorrectableSector)
                   titre="🔴 Disque : secteurs illisibles" ;;
  Usage)           titre="🟠 Disque : indicateur SMART qui se dégrade" ;;
  SelfTest)        titre="🟠 Disque : autotest SMART en échec" ;;
  ErrorCount)      titre="🟠 Disque : nouvelles erreurs" ;;
  Temperature)     titre="🌡️ Disque trop chaud" ;;
  FailedOpenDevice|FailedReadSmartData|FailedHealthCheck|FailedReadSmartErrorLog|FailedReadSmartSelfTestLog)
                   titre="⚠️ Disque : SMART illisible (disque débranché ou en panne ?)" ;;
  Fsck)            titre="🔴 Système de fichiers endommagé (e2scrub)" ;;
  *)               titre="⚠️ Disque : $SMARTD_FAILTYPE" ;;
esac
texte="$titre — $(hostname -s)

${SMARTD_MESSAGE:-Message de test : la chaîne smartd -> Telegram fonctionne.}

Disque : ${SMARTD_DEVICEINFO:-$SMARTD_DEVICE}
Périphérique : $SMARTD_DEVICE${SMARTD_TFIRST:+
Première détection : $SMARTD_TFIRST}"

if curl -s -m 20 -o /dev/null -w '%{http_code}' "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
     --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${texte}" | grep -q 200; then
  logger -t smartd-alerte "Telegram OK : $SMARTD_FAILTYPE $SMARTD_DEVICE"
else
  logger -t smartd-alerte "ERREUR envoi Telegram : $SMARTD_FAILTYPE $SMARTD_DEVICE"; exit 1
fi
