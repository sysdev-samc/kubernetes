#!/bin/bash
# Copie les secrets (fichiers ignorés par git) de ce nas vers nas1, par SSH,
# puis vérifie que les copies sont identiques et protégées.
# Les secrets ne passent JAMAIS par git ni GitHub, et leur contenu n'est jamais affiché.
#
# À lancer sur nas2, après chaque modification d'un secret (ex. vpn.env).
# Prérequis : le dépôt est déjà cloné sur nas1 dans /ssd1/kubernetes.
#
# Usage : bash /ssd1/kubernetes/copie-secrets-nas1.sh        # copie + vérification
#         bash /ssd1/kubernetes/copie-secrets-nas1.sh -n     # liste seulement (rien n'est copié)
set -e -o pipefail
DEST=nas1
DIR=/ssd1/kubernetes
cd "$DIR"

# 1. Liste des secrets : fichiers ignorés par git, hors fichiers jetables (logs, sauvegardes)
mapfile -t files < <(git ls-files --others --ignored --exclude-standard | grep -vE '\.log$|\.bak|~$' | sort)
[ ${#files[@]} -gt 0 ] || { echo "Aucun secret trouvé."; exit 0; }
echo "=== Secrets à copier vers $DEST :"
for f in "${files[@]}"; do printf '  %-40s droits %s\n' "$f" "$(stat -c %a "$f")"; done

# Un secret lisible par d'autres que root serait recopié tel quel : on refuse
for f in "${files[@]}"; do
  [ "$(stat -c %a "$f")" = "600" ] || { echo "ERREUR : $f n'est pas en 600 (chmod 600 $f)"; exit 1; }
done
[ "$1" = "-n" ] && { echo "(mode liste : rien n'a été copié)"; exit 0; }

# 2. nas1 joignable et dépôt présent ?
ssh -o BatchMode=yes -o ConnectTimeout=5 "$DEST" "test -d $DIR/.git" \
  || { echo "ERREUR : $DEST injoignable ou dépôt absent. Sur $DEST : git clone nas2:$DIR $DIR"; exit 1; }

# 3. Copie (dossiers créés en 700, fichiers gardent leurs droits 600 grâce à -p)
echo; echo "=== Copie"
for f in "${files[@]}"; do
  d=$(dirname "$f")
  ssh "$DEST" "test -d $DIR/$d || install -d -m 700 $DIR/$d"
  scp -q -p "$f" "$DEST:$DIR/$f"
  echo "  copié : $f"
done
# Les dossiers qui ne contiennent que des secrets (ex. gluetun/) : 700 de chaque côté
for d in $(printf '%s\n' "${files[@]}" | xargs -n1 dirname | sort -u); do
  [ "$d" = "." ] && continue
  git ls-files --error-unmatch "$d" >/dev/null 2>&1 || ssh "$DEST" "chmod 700 $DIR/$d"
done

# 4. Vérification : mêmes empreintes, mêmes droits (sans afficher le contenu)
echo; echo "=== Vérification"
ok=1
for f in "${files[@]}"; do
  local_sum=$(sha256sum "$f" | cut -d' ' -f1)
  read -r remote_sum remote_mode < <(ssh "$DEST" "echo \$(sha256sum $DIR/$f | cut -d' ' -f1) \$(stat -c %a $DIR/$f)")
  if [ "$local_sum" = "$remote_sum" ] && [ "$remote_mode" = "600" ]; then
    printf '  OK   %-40s identique, droits %s\n' "$f" "$remote_mode"
  else
    printf '  KO   %-40s empreinte %s, droits %s\n' "$f" "$([ "$local_sum" = "$remote_sum" ] && echo identique || echo DIFFÉRENTE)" "$remote_mode"
    ok=0
  fi
done
[ $ok = 1 ] && echo "Tous les secrets sont à jour sur $DEST." || { echo "ATTENTION : au moins un secret n'est pas correct sur $DEST."; exit 1; }
