# Development

Tech stack, commands, conventions, and environment notes for the ADS-B demo.
See [`../AGENTS.md`](../AGENTS.md) for agent behaviour and operating rules.

______________________________________________________________________

## Tech Stack & Commands

- **Runtime**: Docker & Docker Compose
- **Data pipeline**: Elastic Agent 9.x (CEL inputs polling the OpenSky Network API; Logstash is an optional fallback)
- **Search & storage**: Elasticsearch (time-series data stream with geo-shape enrichment)
- **Visualisation**: Kibana (dashboards, data views)
- **Setup automation**: Bash (`setup.sh`)

| Command                      | Purpose                                                                  |
| ---------------------------- | ------------------------------------------------------------------------ |
| `cp .env.example .env`       | Create local environment config                                          |
| `make setup`                 | Create ES indices, enrich policy, ingest pipeline, import Kibana objects |
| `make setup-no-service-user` | Run full setup without service user (actions attributed to .env API key) |
| `make deploy-ilm`            | Deploy ES ILM policy only (skipped on Serverless)                        |
| `make deploy-indices`        | Deploy ES index templates and data streams only                          |
| `make deploy-enrich`         | Deploy ES enrich policies only                                           |
| `make deploy-pipelines`      | Deploy ES ingest pipelines only                                          |
| `make deploy-kibana`         | Deploy Kibana saved objects (dashboards, data views) only                |
| `make deploy-cases`          | Deploy case configuration (custom fields, templates)                     |
| `make deploy-workflows`      | Deploy Kibana workflows only                                             |
| `make deploy-tools`          | Deploy Agent Builder workflow tools only                                 |
| `make deploy-skills`         | Deploy Agent Builder skills only                                         |
| `make deploy-agents`         | Deploy Kibana AI agents only                                             |
| `make deploy-demouser`       | Deploy demo user roles and users only                                    |
| `make deploy-es`             | Deploy all ES resources (ilm + indices + enrich + pipelines)             |
| `make deploy-ai`             | Deploy AI layer (workflows + tools + skills + agents)                    |
| `make redeploy`              | Re-deploy all resources (force overwrite)                                |
| `make up`                    | Start ingest (`COMPOSE_PROFILES=agent` by default; `logstash` for Logstash) |
| `make down`                  | Stop ingest (both Agent and Logstash profiles)                           |
| `make logs`                  | Tail ingest logs                                                         |
| `make restart`               | Restart running ingest containers after config changes                   |
| `make status`                | Show ingest status                                                       |
| `make clean`                 | Stop ingest and remove volumes                                           |
| `make validate`              | Validate Docker Compose config                                           |
| `make health`                | Check Elasticsearch cluster health                                       |
| `make ps`                    | Show running containers                                                  |
| `make shell`                 | Open a shell inside the running ingest container                         |
| `make help`                  | List all available targets (grouped)                                     |

Any deploy target accepts `FORCE=1` to overwrite existing resources, e.g. `make deploy-agents FORCE=1`.

______________________________________________________________________

## Key Conventions

- Never edit `.env` directly in commits; only reference `.env.example`.
- Elastic Agent policy lives in `elastic-agent/elastic-agent.yml`; Logstash pipeline configs live in `logstash/pipeline/`; Elasticsearch resources in `elasticsearch/`.
- The four quadrant inputs (`adsb-q1`–`adsb-q4`) are intentionally separate to spread load across bounding boxes.

______________________________________________________________________

## Docker Access

This project relies on Docker for its ingest services (Elastic Agent by default,
Logstash as a fallback). AI assistants
running in sandboxed environments (e.g. Cursor) often cannot reach the Docker
daemon under default sandbox restrictions.

**Always request elevated permissions for Docker commands.** Use
`required_permissions: ["all"]` for any `docker` or `docker compose` command
(including `docker ps`, `docker logs`, `docker stats`, `docker volume`,
`docker inspect`, etc.). Read-only Docker queries still require the Docker
socket, which the sandbox blocks.

```sh
# Correct — works reliably
Shell(command="docker ps", required_permissions=["all"])

# Wrong — will silently fail with empty output or exit code 1
Shell(command="docker ps")
Shell(command="docker ps", required_permissions=["full_network"])
```

______________________________________________________________________

## Post-change Checklist

After code changes:

1. Verify Docker Compose config parses: `docker compose config --quiet`
   (request `required_permissions: ["all"]`; see [Docker Access](#docker-access)).
2. If ingest configs changed, `make validate` then `make restart`.
3. Summarise edits, mention tests, and flag follow-up work in the final response.

______________________________________________________________________

## Related Reference

- **Dashboard management** (export, version tracking, redeploy): [`dashboard-management.md`](dashboard-management.md)
- **Elastic Skills & MCP Servers**: [`elastic-skills-mcp.md`](elastic-skills-mcp.md)
- **Testing via API**: [`testing-api.md`](testing-api.md)
- **Known Quirks**: [`known-quirks.md`](known-quirks.md)
- **Releasing**: [`RELEASING.md`](RELEASING.md)
