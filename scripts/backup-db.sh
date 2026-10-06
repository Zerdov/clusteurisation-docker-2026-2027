#!/usr/bin/env bash
# Sauvegarde logique de la base Nebula : pg_dump s'execute dans le conteneur de la base
# (sur worker1, le noeud de donnees) et le fichier est ecrit dans backups/ sur l'hote.
# Une sauvegarde par execution, horodatee. Format : SQL compresse, rejouable avec psql.
#   bash scripts/backup-db.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/lab.sh

mkdir -p backups
FICHIER="backups/nebula-$(date +%Y%m%d-%H%M%S).sql.gz"
db=$(conteneur_db)
[ -n "$db" ] || { echo "!! base introuvable sur $W1 : le lab est-il monte ?"; exit 1; }

# --clean --if-exists : la restauration remplace les tables existantes au lieu de echouer
dkw1 exec "$db" pg_dump -U nebula -d nebula --clean --if-exists | gzip > "$FICHIER"
echo "sauvegarde ecrite : $FICHIER ($(du -h "$FICHIER" | cut -f1))"
