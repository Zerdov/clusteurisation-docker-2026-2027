#!/usr/bin/env bash
# Panne du plan de donnees. Deux preuves :
#   A. la donnee survit a l'arret et au redemarrage de la base (volume local a worker1) ;
#   B. apres une perte simulee, la restauration depuis une sauvegarde remet la donnee.
#   bash scripts/data-restore-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/lab.sh

sql() { dkw1 exec "$(conteneur_db)" psql -U nebula -d nebula -tAc "$1"; }
lire() { curl -s -o /dev/null -w '%{http_code}' -m 5 "$API/api/comptes/$1"; }
est_present() { [ "$(lire "$1")" = 200 ]; }

echo "== panne du plan de donnees"
ID=$(curl -fsS -m 10 -X POST "$API/api/comptes" -H 'content-type: application/json' \
  -d "{\"pseudo\":\"donnee-$RANDOM\"}" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
verdict "compte de test cree (id=$ID)" $([ -n "$ID" ] && echo 0 || echo 1)
[ -n "$ID" ] || { bilan; exit 1; }

echo "-- A. arret et redemarrage de la base"
dk service update --force nebula_db >/dev/null
sleep 5
attendre "dk service ls --format '{{.Name}} {{.Replicas}}' | grep -qx 'nebula_db 1/1'" 120
attendre "est_present $ID" 60
if est_present "$ID"; then r=0; else r=1; fi
verdict "compte $ID toujours present apres redemarrage de la base" $r

echo "-- B. sauvegarde, perte simulee, restauration"
./scripts/backup-db.sh >/dev/null
SAUV=$(ls -t backups/nebula-*.sql.gz | head -1)
verdict "sauvegarde produite : $SAUV" $([ -s "$SAUV" ] && echo 0 || echo 1)

sql "DELETE FROM comptes WHERE id=$ID" >/dev/null
if est_present "$ID"; then r=1; else r=0; fi
verdict "perte simulee : compte $ID supprime" $r

./scripts/restore-db.sh "$SAUV" >/dev/null
if est_present "$ID"; then r=0; else r=1; fi
verdict "restauration appliquee : compte $ID de nouveau present" $r

bilan
