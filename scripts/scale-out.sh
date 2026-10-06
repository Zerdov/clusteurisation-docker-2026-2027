#!/usr/bin/env bash
# Montee en charge d'un service sans etat : nebula_comptes passe de son
# nombre initial a CIBLE instances, et les requetes doivent se repartir sur toutes.
# Le nombre initial est retabli a la sortie, meme en cas d'erreur.
#   N_CIBLE=4 REQUETES=300 bash scripts/scale-out.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/lab.sh

CIBLE=${N_CIBLE:-4}
REQUETES=${REQUETES:-300}
INITIAL=$(dk service inspect nebula_comptes --format '{{.Spec.Mode.Replicated.Replicas}}')
trap 'dk service scale nebula_comptes='"$INITIAL"' >/dev/null 2>&1' EXIT

echo "== nebula_comptes de $INITIAL a $CIBLE instances"
dk service scale nebula_comptes="$CIBLE" >/dev/null
attendre "dk service ls --format '{{.Name}} {{.Replicas}}' | grep -qx 'nebula_comptes $CIBLE/$CIBLE'" 120
verdict "$CIBLE instances en marche" $?

# Traefik relit l'etat du cluster toutes les 10 s : on attend qu'il voie toutes les instances
attendre "[ \$(hotes_distincts 20) -ge $CIBLE ]" 90
verdict "Traefik voit les $CIBLE instances" $?

# une seule mesure : on calcule le succes et la repartition sur les memes reponses
mesure=$(repartition "$REQUETES")
ok=$(printf '%s\n' "$mesure" | awk '{ s += $1 } END { print s + 0 }')
distincts=$(printf '%s\n' "$mesure" | grep -c . || true)
verdict "$ok requetes sur $REQUETES reussies" $([ "$ok" -eq "$REQUETES" ] && echo 0 || echo 1)
verdict "repartition sur $CIBLE instances (instances distinctes : $distincts)" \
  $([ "$distincts" -eq "$CIBLE" ] && echo 0 || echo 1) "$(printf '%s\n' "$mesure" | sed 's/^/ /')"

bilan
