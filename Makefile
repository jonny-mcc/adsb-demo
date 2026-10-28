FORCE_FLAG := $(if $(FORCE),--force,)

# Ingest profile: `make up INGEST_ENGINE=logstash` overrides .env COMPOSE_PROFILES.
# Otherwise use COMPOSE_PROFILES from .env (what Docker Compose reads), then agent.
ifndef INGEST_ENGINE
  INGEST_ENGINE := $(shell grep -E '^INGEST_ENGINE=' .env 2>/dev/null | tail -1 | cut -d= -f2)
endif
ifndef COMPOSE_PROFILES
  COMPOSE_PROFILES := $(shell grep -E '^COMPOSE_PROFILES=' .env 2>/dev/null | tail -1 | cut -d= -f2)
endif
ifneq ($(strip $(INGEST_ENGINE)),)
  export COMPOSE_PROFILES := $(INGEST_ENGINE)
else ifeq ($(strip $(COMPOSE_PROFILES)),)
  export COMPOSE_PROFILES := agent
else
  export COMPOSE_PROFILES
endif

.PHONY: setup setup-no-service-user deploy-ilm deploy-indices deploy-enrich deploy-pipelines deploy-kibana \
        deploy-cases deploy-workflows deploy-tools deploy-skills deploy-agents deploy-demouser \
        deploy-es deploy-ai redeploy \
        up down logs restart status clean \
        validate health ps shell help

# ---------------------------------------------------------------------------
##@ Setup / Deploy
# ---------------------------------------------------------------------------

setup:              ## Run full Elasticsearch setup (skip existing)
	./setup.sh $(FORCE_FLAG)

setup-no-service-user: ## Run full setup without service user (actions attributed to .env API key owner)
	./setup.sh --no-service-user $(FORCE_FLAG)

deploy-ilm:         ## Deploy ES ILM policy (skipped on Serverless)
	./setup.sh --only ilm $(FORCE_FLAG)

deploy-indices:     ## Deploy ES index templates and data streams
	./setup.sh --only indices $(FORCE_FLAG)

deploy-enrich:      ## Deploy ES enrich policies
	./setup.sh --only enrich $(FORCE_FLAG)

deploy-pipelines:   ## Deploy ES ingest pipelines
	./setup.sh --only pipelines $(FORCE_FLAG)

deploy-kibana:      ## Deploy Kibana saved objects (dashboards, data views)
	./setup.sh --only kibana $(FORCE_FLAG)

deploy-cases:       ## Deploy case configuration (custom fields, templates)
	./setup.sh --only cases $(FORCE_FLAG)

deploy-workflows:   ## Deploy Kibana workflows
	./setup.sh --only workflows $(FORCE_FLAG)

deploy-tools:       ## Deploy Agent Builder workflow tools
	./setup.sh --only tools $(FORCE_FLAG)

deploy-skills:      ## Deploy Agent Builder skills
	./setup.sh --only skills $(FORCE_FLAG)

deploy-agents:      ## Deploy Kibana AI agents
	./setup.sh --only agents $(FORCE_FLAG)

deploy-demouser:    ## Deploy demo user roles and users
	./setup.sh --only demouser --no-service-user $(FORCE_FLAG)

deploy-es:          ## Deploy all ES resources (ilm + indices + enrich + pipelines)
	./setup.sh --only ilm,indices,enrich,pipelines $(FORCE_FLAG)

deploy-ai:          ## Deploy AI layer (workflows + tools + skills + agents)
	./setup.sh --only workflows,tools,skills,agents $(FORCE_FLAG)

redeploy:           ## Re-deploy all resources (force overwrite)
	./setup.sh --force

# ---------------------------------------------------------------------------
##@ Ingest
# ---------------------------------------------------------------------------

up:                 ## Start ingest (Elastic Agent by default; INGEST_ENGINE=logstash for Logstash)
	docker compose up -d

down:               ## Stop ingest (both agent and logstash profiles)
	docker compose --profile agent --profile logstash down

logs:               ## Tail ingest logs
	docker compose logs -f

restart:            ## Restart running ingest containers after config changes
	docker compose restart

status:             ## Show ingest status
	@echo "INGEST_ENGINE=$(INGEST_ENGINE) COMPOSE_PROFILES=$(COMPOSE_PROFILES)"
	@docker compose --profile agent --profile logstash ps
	@if docker compose --profile agent ps --status running --services 2>/dev/null | grep -qx elastic-agent; then \
	  echo "--- Elastic Agent ---"; \
	  docker compose exec -T elastic-agent elastic-agent status || true; \
	fi
	@if docker compose --profile logstash ps --status running --services 2>/dev/null | grep -qx logstash; then \
	  echo "--- Logstash pipelines ---"; \
	  docker compose exec -T logstash curl -s localhost:9600/_node/pipelines?pretty || true; \
	fi

clean:              ## Stop ingest and remove volumes (both profiles)
	docker compose --profile agent --profile logstash down -v

# ---------------------------------------------------------------------------
##@ Diagnostics
# ---------------------------------------------------------------------------

validate:           ## Validate Docker Compose config
	docker compose config --quiet && echo "Docker Compose config is valid."

health:             ## Check Elasticsearch cluster health
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi; \
	curl -s "$${ES_ENDPOINT%/}/_cluster/health?pretty" \
	  -H "Authorization: ApiKey $${ES_API_KEY_ENCODED}"

ps:                 ## Show running containers (both ingest profiles)
	docker compose --profile agent --profile logstash ps

shell:              ## Open a shell inside the running ingest container
	@if docker compose --profile agent ps --status running --services 2>/dev/null | grep -qx elastic-agent; then \
	  docker compose exec elastic-agent bash; \
	elif docker compose --profile logstash ps --status running --services 2>/dev/null | grep -qx logstash; then \
	  docker compose exec logstash bash; \
	else \
	  echo "No ingest container is running. Start one with: make up"; \
	  exit 1; \
	fi

# ---------------------------------------------------------------------------
##@ Help
# ---------------------------------------------------------------------------

help:               ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
