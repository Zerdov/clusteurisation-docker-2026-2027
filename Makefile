SHELL    := /bin/bash
REGISTRY ?= registry.local:5000
TAG      ?= v1
HOST     ?= nebula.local

.DEFAULT_GOAL := help
.PHONY: help dev dev-down build edge deploy smoke clean

help: ## Affiche cette aide
	@grep -hE '^[a-z0-9-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-10s\033[0m %s\n",$$1,$$2}'

dev: ## Lance les 7 services en local, hors Swarm (verification rapide)
	docker compose -f compose.dev.yml up --build -d && docker compose -f compose.dev.yml ps
dev-down: ## Arrete l'environnement local
	docker compose -f compose.dev.yml down
build: ## Construit et pousse les 3 images
	REGISTRY=$(REGISTRY) ./scripts/build-push.sh $(TAG)
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

.PHONY: lab-up lab-verify lab-demo lab-down lab-reset

lab-up: ## Monte le lab Swarm local a trois noeuds (idempotent)
	bash lab/up.sh
lab-verify: ## Verifie le lab (lecture seule, code de sortie = echecs)
	bash lab/verify-lab.sh
lab-demo: ## Demo : panne d'un worker, reprogrammation, retour
	bash lab/demo-panne.sh
lab-down: ## Arrete le lab, garde les volumes
	bash lab/down.sh
lab-reset: ## DESTRUCTIF : supprime le lab et ses volumes (demande confirmation)
	bash lab/reset.sh

.PHONY: vm-up vm-tunnel

vm-up: ## Deploie Nebula sur les VM (SSH_USER=manager, rebond dans ~/.ssh/config)
	SSH_USER=$${SSH_USER:-manager} bash scripts/vm-up.sh
vm-tunnel: ## Tunnel SSH : API sur localhost:18080, dashboard sur localhost:18088
	ssh -fN -L 18080:localhost:80 -L 18088:localhost:8088 $${SSH_USER:-manager}@10.96.238.1

.PHONY: scale-out rolling-update rollback data-restore-test add-service backup-db restore-db

scale-out: ## montee en charge de nebula_comptes
	bash scripts/scale-out.sh
rolling-update: ## mise a jour sans interruption
	bash scripts/rolling-update.sh
rollback: ## version defectueuse puis retour arriere
	bash scripts/rollback.sh
data-restore-test: ## persistance et restauration de la base
	bash scripts/data-restore-test.sh
add-service: ## ajout d'un huitieme service
	bash scripts/add-service.sh
backup-db: ## Sauvegarde la base dans backups/
	bash scripts/backup-db.sh
restore-db: ## Restaure la base : make restore-db FILE=backups/xxx.sql.gz
	bash scripts/restore-db.sh $(FILE)
