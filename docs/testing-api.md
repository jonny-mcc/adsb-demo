# Testing via API

On the supported 9.5 baseline, validate agent, workflow deployment, alert wiring,
and trace collection through the Elasticsearch and Kibana REST APIs.
All commands require `required_permissions: ["all"]` in sandboxed environments.

## Prerequisites

```sh
source .env   # provides ES_ENDPOINT, KB_ENDPOINT, ES_API_KEY_ENCODED

# Space-aware Kibana base URL (all Kibana API calls must use KB_BASE)
KB_BASE="${KB_ENDPOINT%/}"
[[ -n "${KB_SPACE:-}" ]] && KB_BASE="${KB_BASE}/s/${KB_SPACE}"
```

## Redeploy changed resources

```sh
./setup.sh --only agents,workflows --force
```

## Test an Elasticsearch query

Run the query body directly against ES to validate aggregations, painless scripts, and
mappings before deploying a workflow.

```sh
curl -s "${ES_ENDPOINT}/demos-aircraft-adsb/_search" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "Content-Type: application/json" \
  -d '{"size":0,"query":{...},"aggs":{...}}' | jq '.aggregations'
```

## Test a workflow

The Kibana Workflows API (Technical Preview) requires the extra header
`x-elastic-internal-origin: kibana` on every request.

```sh
# 1. Use the source-controlled workflow ID
WF_ID=adsb-squawk-7500-hijack-investigation

# 2. Run — NOTE: path changed in 9.4.x, now requires "workflow/" segment
EXEC_ID=$(curl -s -X POST "${KB_BASE}/api/workflows/workflow/${WF_ID}/run" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: kibana" \
  -H "Content-Type: application/json" \
  -d '{"inputs":{}}' | jq -r '.workflowExecutionId')

# 3. Poll until status is "completed" or "failed"
curl -s "${KB_BASE}/api/workflows/executions/${EXEC_ID}" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: kibana" \
  | jq '{status, duration, steps: [.stepExecutions[]? | {type: .stepType, status: .status}]}'

# 4. Inspect individual step output
STEP_ID=$(curl -s "${KB_BASE}/api/workflows/executions/${EXEC_ID}" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: kibana" \
  | jq -r '.stepExecutions[0].id')

curl -s "${KB_BASE}/api/workflows/executions/${EXEC_ID}/step/${STEP_ID}" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: kibana" | jq '.output'
```

For workflows with inputs, pass them in the run body:
`-d '{"inputs":{"icao24":"a1b2c3","callsign":"DAL123"}}'`

## Test an agent

Use the Agent Builder converse API to send a message and inspect the response.

```sh
curl -s -X POST "${KB_BASE}/api/agent_builder/converse" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"${AGENT_ID}","input":"Your test prompt here"}' \
  | jq '{status, model: .model_usage.model, response: .response.message}'
```

## Side-effect awareness

Some workflows trigger real external actions when run:

| Workflow                           | Side effects                                  |
| ---------------------------------- | --------------------------------------------- |
| `adsb-aggregate-stats`             | None (read-only ES query)                     |
| `daily-flight-briefing`            | Sends Slack message, invokes AI agent         |
| `squawk-7500-enrich`               | External HTTP calls (adsbdb, adsb.lol, GNews) |
| `squawk-7500-hijack-investigation` | Creates Kibana case, may send Slack           |
| `squawk-7500-create-case`          | Creates or updates a Kibana case              |

Agent converse calls may invoke workflow tools and incur LLM costs.

## Verify alert action wiring

```sh
curl -s "${KB_BASE}/api/alerting/rule/7500a1e7-cafe-4bee-b500-deadbeef7500" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  | jq '.actions[] | {
      connector: .id,
      workflow_id: .params.subActionParams.workflowId
    }'
```

The workflow ID must be `adsb-squawk-7500-hijack-investigation`.

## Verify dashboard-as-code deployment

```sh
curl -s "${KB_BASE}/api/dashboards/adsb-operations-cases" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  | jq '{title, panels: (.panels | length), controls: (.pinned_panels | length)}'
```

Expect the **ADS-B Operations & Cases** title, five panels, and two pinned
controls. Spatial Maps remain in the saved-object dashboards because the 9.5
Dashboards API does not support Maps panels.

## Verify Agent Builder traces

After one agent conversation:

```sh
curl -s "${ES_ENDPOINT}/traces-agent_builder.otel-*/_count" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}"
```

The managed **[Elastic] Agent Builder Overview** dashboard is installed per
space by `make deploy-workflows`.
