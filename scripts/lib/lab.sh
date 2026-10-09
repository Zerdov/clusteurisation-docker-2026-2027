#!/usr/bin/env bash
# Outils communs aux scripts de test du cluster Swarm sur les 4 VM VirtualBox
# (docs/vm-installation-virtualbox.md : registry a part, manager, worker1, worker2).
# A sourcer depuis un script de scripts/ :
#   source "$(dirname "$0")/lib/lab.sh"
# N'execute rien a l'import : uniquement des constantes et des fonctions.
# Pas de MSYS_NO_PATHCONV=1 ici (contrairement a l'ancien mode Docker-in-Docker, qui
# passait des chemins internes a un conteneur type /repo/... a proteger de la conversion) :
# rollback.sh a besoin au contraire que $ctx (repertoire temporaire local, mktemp -d)
# soit bien traduit en chemin Windows pour que "docker build" (binaire natif) le trouve.

# Topologie fixe du lab : pas des parametres, ce sont des faits sur ces 4 VM precises.
# A editer ici si le lab change d'adressage, pas a redefinir a chaque commande.
SSH_USER_MANAGER=manager
SSH_USER_WORKER=worker       # meme utilisateur sur worker1 et worker2
MANAGER_IP=192.168.56.11
W1_IP=192.168.56.12
W2_IP=192.168.56.13
REGISTRY_IP=192.168.56.10
# Registry a part (hors Swarm) : meme adresse vue de l'hote et des noeuds, joignable
# directement sur le reseau Host-only. Deux noms pour rester compatible avec les scripts
# qui distinguaient les deux points de vue (REG_HOTE/REG_NOEUDS) ; ici c'est la meme valeur.
REG_HOTE=$REGISTRY_IP:5000
REG_NOEUDS=$REGISTRY_IP:5000
API=http://$MANAGER_IP
DASH=http://$MANAGER_IP:8088

ECHECS=0

# dk <args...>     : client docker du manager
# dkw1 <args...>   : client docker du worker1
# dknode <ip> <args...> : client docker d'un noeud quelconque (ip inconnue a l'avance,
#                    ex. scripts/fault-tolerance.sh qui cible la tache ou qu'elle tourne)
dk()     { docker -H "ssh://$SSH_USER_MANAGER@$MANAGER_IP" "$@"; }
dkw1()   { docker -H "ssh://$SSH_USER_WORKER@$W1_IP" "$@"; }
dknode() {
  local ip=$1; shift
  local u=$SSH_USER_WORKER
  [ "$ip" = "$MANAGER_IP" ] && u=$SSH_USER_MANAGER
  docker -H "ssh://$u@$ip" "$@"
}

# attendre "<commande>" <secondes> : reussit des que la commande reussit
attendre() {
  for _ in $(seq 1 "$2"); do
    eval "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

conteneur_db() { dkw1 ps -q --filter name=nebula_db | head -1; }

# stack_deploy <nom> <fichier> : deploie une stack avec --with-registry-auth sur le manager.
# REGISTRY et TAG sont lus dans l'environnement (ex. REGISTRY=... TAG=... stack_deploy ...).
# Le fichier est copie dans ~/nebula avant (le manager ne l'a pas forcement).
stack_deploy() {
  local nom=$1 fichier=$2
  ssh -o BatchMode=no "$SSH_USER_MANAGER@$MANAGER_IP" "mkdir -p ~/nebula/$(dirname "$fichier")" \
    && scp -q "$fichier" "$SSH_USER_MANAGER@$MANAGER_IP:~/nebula/$fichier" \
    && ssh -o BatchMode=no "$SSH_USER_MANAGER@$MANAGER_IP" \
         "cd ~/nebula && REGISTRY='$REGISTRY' TAG='$TAG' docker stack deploy -c $fichier --with-registry-auth $nom"
}

# build_push <image:tag> <contexte> [args de build...] : build envoye au manager par contexte
# SSH, push depuis le manager (deja logge sur le registry, le poste ne l'est pas forcement).
build_push() {
  local img=$1 ctx=$2
  shift 2
  dk build -q "$@" -t "$img" "$ctx" >/dev/null \
    && ssh -o BatchMode=no "$SSH_USER_MANAGER@$MANAGER_IP" "docker push -q $img" >/dev/null
}

api_ok() { curl -fsS -m 5 "$API/api/health" >/dev/null 2>&1; }

# hotes <n> : une ligne par reponse reussie de /api/health, avec le hostname de l'instance.
# Le parsing se fait DANS chaque processus : une seule ecriture par ligne, donc pas de
# reponses collees entre elles quand xargs tourne en parallele.
hotes() {
  seq "$1" | xargs -P 10 -I{} sh -c \
    'curl -fsS -m 5 -w "\n" "$1" 2>/dev/null | sed -n "s/.*\"host\":\"\([^\"]*\)\".*/\1/p"' _ "$API/api/health"
}
# repartition <n> : nombre de requetes servies par instance
repartition() { hotes "$1" | sort | uniq -c | sort -rn; }
# hotes_distincts <n> : nombre d'instances differentes ayant repondu
hotes_distincts() { hotes "$1" | sort -u | grep -c . || true; }

# verdict "<libelle>" <0|1> [detail] : affiche le resultat et compte les echecs (0 = reussi)
verdict() {
  if [ "$2" -eq 0 ]; then
    printf '  OK     %s\n' "$1"
  else
    printf '  ECHEC  %s\n' "$1"
    ECHECS=$((ECHECS + 1))
  fi
  if [ -n "${3:-}" ]; then printf '         %s\n' "$3"; fi
  return 0
}

# bilan : resume le test, renvoie 1 si un controle a echoue
bilan() {
  echo
  if [ "$ECHECS" -eq 0 ]; then
    echo "TEST REUSSI"
    return 0
  fi
  echo "TEST ECHOUE ($ECHECS controle(s) en echec)"
  return 1
}
