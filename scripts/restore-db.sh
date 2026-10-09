#!/usr/bin/env bash
# Restauration de la base Nebula depuis une sauvegarde produite par backup-db.sh.
# Les donnees ecrites APRES la sauvegarde sont perdues : c'est le prix de la sauvegarde
# logique periodique (RPO = intervalle entre deux sauvegardes).
#   bash scripts/restore-db.sh backups/nebula-AAAAMMJJ-HHMMSS.sql.gz
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/lab.sh

FICHIER=${1:?usage : restore-db.sh <fichier.sql.gz>}
[ -f "$FICHIER" ] || { echo "!! fichier introuvable : $FICHIER"; exit 1; }
db=$(conteneur_db)
[ -n "$db" ] || { echo "!! base introuvable sur worker1 ($W1_IP) : le service nebula_db tourne-t-il ?"; exit 1; }

# ON_ERROR_STOP : une erreur stoppe la restauration au lieu de laisser une base a moitie restauree
gunzip -c "$FICHIER" | dkw1 exec -i "$db" \
  psql -q -U nebula -d nebula -v ON_ERROR_STOP=1
echo "restauration appliquee depuis $FICHIER"
