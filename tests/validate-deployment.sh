#!/usr/bin/env bash
set -euo pipefail

: "${ES_ENDPOINT:?ES_ENDPOINT is required}"
: "${ES_API_KEY_ENCODED:?ES_API_KEY_ENCODED is required}"
: "${KB_ENDPOINT:?KB_ENDPOINT is required}"

BASE="${ES_ENDPOINT%/}"
KB_BASE="${KB_ENDPOINT%/}"
[[ -n "${KB_SPACE:-}" ]] && KB_BASE="$KB_BASE/s/$KB_SPACE"
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-cloud-hosted}"

es_curl() {
  curl -fsS -H "Authorization: ApiKey $ES_API_KEY_ENCODED" "$@"
}

kb_curl() {
  curl -fsS \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    "$@"
}

version=$(es_curl "$BASE" | jq -r '.version.number')
[[ "$version" =~ ^9\.([5-9]|[1-9][0-9])\. ]] || {
  echo "Elastic 9.5+ required; found $version" >&2
  exit 1
}

template=$(es_curl "$BASE/_index_template/demos-aircraft-adsb")
jq -e '
  .index_templates[0].index_template.template.lifecycle.enabled == true
  and (.index_templates[0].index_template.template.settings.index.lifecycle | not)
' <<< "$template" >/dev/null

workflow_ids=(
  adsb-aggregate-stats
  adsb-aircraft-history
  adsb-airport-activity
  adsb-daily-flight-briefing
  adsb-defunct-callsign-detector
  adsb-hijack-cases-summary
  adsb-squawk-7500-create-case
  adsb-squawk-7500-enrich
  adsb-squawk-7500-hijack-investigation
)
for workflow_id in "${workflow_ids[@]}"; do
  kb_curl "$KB_BASE/api/workflows/workflow/$workflow_id" >/dev/null
done

dashboard=$(kb_curl "$KB_BASE/api/dashboards/adsb-operations-cases")
jq -e '
  .title == "ADS-B Operations & Cases"
  and (.panels | length) == 5
  and (.pinned_panels | length) == 2
' <<< "$dashboard" >/dev/null

if [[ "$DEPLOYMENT_TYPE" != "serverless" ]]; then
  rule=$(kb_curl "$KB_BASE/api/alerting/rule/7500a1e7-cafe-4bee-b500-deadbeef7500")
  jq -e '
    .actions[]
    | select(
        .id == "system-connector-.workflows"
        and .params.subActionParams.workflowId
          == "adsb-squawk-7500-hijack-investigation"
      )
  ' <<< "$rule" >/dev/null
fi

run_workflow() {
  local workflow_id="$1" inputs="$2" execution_id status=""
  execution_id=$(kb_curl \
    -H "Content-Type: application/json" \
    -X POST "$KB_BASE/api/workflows/workflow/$workflow_id/run" \
    -d "$(jq -n --argjson inputs "$inputs" '{inputs: $inputs}')" |
    jq -r '.workflowExecutionId')
  [[ -n "$execution_id" && "$execution_id" != "null" ]]

  for _ in {1..60}; do
    status=$(kb_curl "$KB_BASE/api/workflows/executions/$execution_id" |
      jq -r '.status')
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" || "$status" == "cancelled" ]] && break
    sleep 2
  done
  echo "Workflow $workflow_id ended with status $status" >&2
  return 1
}

if [[ "${RUN_WORKFLOW_E2E:-false}" == "true" ]]; then
  run_workflow adsb-aggregate-stats '{}'
  run_workflow adsb-aircraft-history \
    '{"icao24":"000000","lookback_hours":1}'
  run_workflow adsb-airport-activity \
    '{"airport":"LHR","lookback_hours":1}'
  run_workflow adsb-defunct-callsign-detector \
    '{"lookback_hours":1}'
  run_workflow adsb-squawk-7500-enrich \
    '{"icao24":"000000","callsign":"TEST000"}'
  if [[ "$DEPLOYMENT_TYPE" != "serverless" ]]; then
    run_workflow adsb-hijack-cases-summary '{}'
    run_workflow adsb-squawk-7500-create-case \
      '{"icao24":"000000","callsign":"TEST000","triage_assessment":"false_positive","confidence":"low","reasoning":"Automated cross-deployment validation."}'
  fi
fi

echo "$DEPLOYMENT_TYPE deployment validation passed on Elastic $version"
