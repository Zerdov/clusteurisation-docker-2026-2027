#!/usr/bin/env bash
# Verifie l'etat du lab Swarm a trois noeuds. LECTURE SEULE : relancable a volonte.
# Code de sortie = nombre de controles en echec (0 = tout est bon).
#
#   bash scripts/verify-lab.sh
#   API=http://nebula.local DASH=http://nebula.local:8088 bash scripts/verify-lab.sh   # sur les VM
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

MANAGER=nebula-lab-manager-1
W1=nebula-lab-worker1-1
W2=nebula-lab-worker2-1
API=${API:-http://localhost:8080}
DASH=${DASH:-http://localhost:8088}
SERVICES="edge_traefik nebula_db nebula_cache nebula_bus nebula_comptes nebula_publications nebula_worker-medias"
ECHECS=0

dk() { docker exec "$MANAGER" docker "$@"; }

controle() { # controle "<libelle>" <fonction> [args...]
  local libelle=$1; shift
  printf '  %-54s' "$libelle"
  if "$@" >/dev/null 2>&1; then echo OK; else echo ECHEC; ECHECS=$((ECHECS + 1)); fi
}

# --- conteneurs des noeuds
conteneurs_up() {
  for c in "$MANAGER" "$W1" "$W2"; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || return 1
  done
}

# --- swarm
swarm_3_ready() { [ "$(dk node ls --format '{{.Status}}' | grep -c '^Ready$')" = 3 ]; }

service_complet() { # service_complet <nom> : replicas tournants = replicas demandes, et > 0
  local r
  r=$(dk service ls --format '{{.Name}} {{.Replicas}}' | awk -v s="$1" '$1 == s { print $2 }')
  [ -n "$r" ] && [ "${r%/*}" = "${r#*/}" ] && [ "${r%/*}" != 0 ]
}

db_sur_worker1() { # contrainte tier=data : la base doit etre sur worker1, et nulle part ailleurs
  [ "$(dk service ps nebula_db --filter desired-state=running --format '{{.Node}}' | sort -u)" = worker1 ]
}

# --- registry (externe au Swarm, authentifie : 401 sans identifiants est le comportement attendu)
registry_protege() { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:5000/v2/)" = 401 ]; }

# --- point d'entree applicatif
# Route de sante exposee par l'edge : /api/health. Non routee aujourd'hui (404),
# voir la note du rapport : controle volontairement en echec tant qu'elle manque.
api_health() { curl -fsS -m 5 "$API/api/health" >/dev/null; }
api_creation() { curl -fsS -m 10 -X POST "$API/api/comptes" -H 'content-type: application/json' \
  -d "{\"pseudo\":\"verif-$RANDOM\"}" >/dev/null; }
api_fil() { curl -fsS -m 10 "$API/api/fil" >/dev/null; }

# --- tableau de bord : protege par basicauth
dash_refuse_sans_mot_de_passe() { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$DASH/")" = 401 ]; }
dash_accepte_avec_mot_de_passe() {
  curl -fsS -m 5 -u "admin:$(cat secrets/dashboard_password.txt)" "$DASH/" >/dev/null
}

# --- hygiene du depot
secrets_hors_git() { git check-ignore -q secrets/registry_password && git check-ignore -q secrets/dashboard_password.txt; }
pas_de_latest() { ! grep -rqE ':latest([^a-zA-Z0-9_-]|$)' swarm/ lab/; }

echo "== noeuds du lab"
controle "3 conteneurs de noeuds en marche" conteneurs_up
controle "swarm : 3 noeuds Ready" swarm_3_ready

echo "== services"
for s in $SERVICES; do
  controle "$s : replicas au complet" service_complet "$s"
done
controle "nebula_db tourne sur worker1 (tier=data)" db_sur_worker1

echo "== registry"
controle "registry authentifie (401 sans identifiants)" registry_protege

echo "== point d'entree ($API)"
controle "GET /api/health" api_health
controle "POST /api/comptes (ecriture en base)" api_creation
controle "GET /api/fil (publications + cache)" api_fil

echo "== tableau de bord ($DASH)"
controle "refuse sans identifiants" dash_refuse_sans_mot_de_passe
controle "accepte avec identifiants" dash_accepte_avec_mot_de_passe

echo "== depot"
controle "secrets ignores par git" secrets_hors_git
controle "aucune image en :latest" pas_de_latest

echo
if [ "$ECHECS" -eq 0 ]; then
  echo "Tous les controles passent."
else
  echo "$ECHECS controle(s) en echec. Diagnostic : docker exec $MANAGER docker service ps <service> --no-trunc"
fi
exit $((ECHECS > 0))
