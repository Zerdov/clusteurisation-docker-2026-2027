SHELL    := /bin/bash
REGISTRY ?= registry.local:5000
TAG      ?= v1
HOST     ?= nebula.local

.DEFAULT_GOAL := help
.PHONY: help dev dev-down edge deploy smoke clean

help: ## Affiche cette aide
	@grep -hE '^[a-z0-9-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-10s\033[0m %s\n",$$1,$$2}'

dev: ## Lance les 7 services en local, hors Swarm (verification rapide)
	docker compose -f compose.dev.yml up --build -d && docker compose -f compose.dev.yml ps
dev-down: ## Arrete l'environnement local
	docker compose -f compose.dev.yml down
edge: ## Deploie le point d'entree Traefik (fourni)
	docker network create --driver overlay --attachable edge_public || true
	docker stack deploy -c swarm/stack.edge.yml edge
deploy: ## Deploie Nebula (votre stack completee)
	REGISTRY=$(REGISTRY) TAG=$(TAG) docker stack deploy \
	  -c swarm/stack.nebula.todo.yml --with-registry-auth nebula
smoke: ## Verifie la chaine complete
	./scripts/smoke.sh $(HOST)
clean: ## Retire la stack
	docker stack rm nebula

.PHONY: scale-out rolling-update rollback fault-tolerance data-restore-test add-service backup-db restore-db

scale-out: ## montee en charge : make scale-out N_CIBLE=4 REQUETES=300
	bash scripts/scale-out.sh
rolling-update: ## mise a jour sans interruption : make rolling-update NOUVEAU=v2
	bash scripts/rolling-update.sh
rollback: ## version defectueuse puis retour arriere
	bash scripts/rollback.sh
fault-tolerance: ## tue une replique en pleine charge : make fault-tolerance SERVICE=nebula_comptes
	bash scripts/fault-tolerance.sh
data-restore-test: ## persistance et restauration de la base
	bash scripts/data-restore-test.sh
add-service: ## ajout d'un huitieme service
	bash scripts/add-service.sh
backup-db: ## Sauvegarde la base dans backups/
	bash scripts/backup-db.sh
restore-db: ## Restaure la base : make restore-db FILE=backups/xxx.sql.gz
	bash scripts/restore-db.sh $(FILE)
