#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

FORCE=false
SKIP_SERVICE_USER=false
SELECTED_GROUPS=""
AVAILABLE_GROUPS="ingestkey space ilm indices enrich pipelines kibana cases workflows tools skills agents demouser"
DEFAULT_GROUPS="space indices enrich pipelines kibana cases workflows tools skills agents demouser"

usage() {
  cat <<EOF
Usage: ./setup.sh [OPTIONS]

Set up Elasticsearch indices, enrich policies, pipelines, Kibana objects,
AI agents, and workflows for the ADS-B demo.

By default, the script creates a dedicated 'adsb-automation' service user
and mints an API key owned by that user, so all deployed resources (alert
rules, workflows, agents) are attributed to the service identity rather
than the human operator. Use --no-service-user to skip this.

If KB_SPACE is set in .env, the Kibana space is created automatically with
the Observability solution view, and all Kibana resources are deployed
into that space.

The service-user step always runs first (unless --no-service-user is passed),
even when --only is used to select a subset of groups.

Options:
  --only GROUP[,GROUP]  Run only the specified groups (comma-separated).
                        Available groups: ${AVAILABLE_GROUPS}
  --force               Overwrite existing resources instead of skipping them.
  --create-ingest-key   Create a least-privilege ingest API key and exit.
  --no-service-user     Skip service user creation; run everything under the
                        original API key from .env.
  --help                Show this help message.

Examples:
  ./setup.sh                               Run all groups (skip existing by default)
  ./setup.sh --only agents,workflows       Re-deploy agents and workflows only
  ./setup.sh --only workflows,tools,skills Re-deploy workflows, tools, and skills
  ./setup.sh --only kibana --force         Reset dashboards to source-controlled versions
  ./setup.sh --create-ingest-key            Print a dedicated ingest key for .env
  ./setup.sh --force                       Overwrite everything
  ./setup.sh --no-service-user             Run all groups without service user
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --create-ingest-key) SELECTED_GROUPS="ingestkey"; SKIP_SERVICE_USER=true; shift ;;
    --only)  SELECTED_GROUPS="$2"; shift 2 ;;
    --no-service-user) SKIP_SERVICE_USER=true; shift ;;
    --help)  usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$SELECTED_GROUPS" ]]; then
  SELECTED_GROUPS="$DEFAULT_GROUPS"
else
  SELECTED_GROUPS="${SELECTED_GROUPS//,/ }"
  for g in $SELECTED_GROUPS; do
    if ! echo "$AVAILABLE_GROUPS" | grep -qw "$g"; then
      echo "ERROR: Unknown group '$g'. Available: $AVAILABLE_GROUPS" >&2
      exit 1
    fi
  done
fi

group_enabled() { echo "$SELECTED_GROUPS" | grep -qw "$1"; }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
else
  echo "ERROR: Environment file not found: $ENV_FILE" >&2
  echo "Copy .env.example to .env and fill in your credentials first." >&2
  exit 1
fi

for var in ES_ENDPOINT ES_API_KEY_ENCODED KB_ENDPOINT; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set. Check your .env file." >&2
    exit 1
  fi
done

BASE="${ES_ENDPOINT%/}"
KB_BASE="${KB_ENDPOINT%/}"
KB_BASE_NO_SPACE="$KB_BASE"
[[ -n "${KB_SPACE:-}" ]] && KB_BASE="${KB_BASE}/s/${KB_SPACE}"
SETUP_API_KEY_ENCODED="$ES_API_KEY_ENCODED"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed." >&2
  echo "Install it: https://jqlang.github.io/jq/download/" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step counting
# ---------------------------------------------------------------------------

group_step_count() {
  case "$1" in
    ingestkey) echo 1 ;;
    space) echo 1 ;;  ilm)       echo 1 ;;
    indices) echo 9 ;; enrich)   echo 4 ;;
    pipelines)
      if [[ "${INGEST_ENGINE:-agent}" == "opensky_integration" ]]; then echo 8; else echo 2; fi
      ;;
    kibana) echo 1 ;;
    cases) echo 1 ;;  agents)    echo 3 ;;
    workflows) echo 14 ;; tools) echo 15 ;;
    skills) echo 7 ;; demouser) echo 1 ;;
    *) echo 0 ;;
  esac
}

TOTAL=0
for g in $SELECTED_GROUPS; do
  TOTAL=$((TOTAL + $(group_step_count "$g")))
done
[[ "$SKIP_SERVICE_USER" == "false" ]] && TOTAL=$((TOTAL + 1))

STEP=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

step_label() {
  STEP=$((STEP + 1))
  echo "[$STEP/$TOTAL] $1 ..."
}

curl_es() {
  curl -s -w '\n%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" "$@"
}

curl_kb() {
  curl -s -w '\n%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" "$@"
}

curl_kb_wf() {
  curl -s -w '\n%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" "$@"
}

parse_response() {
  local body http_code
  body=$(sed '$d' <<< "$1")
  http_code=$(tail -1 <<< "$1")
  echo "$body"
  return 0
}

http_code_of() {
  tail -1 <<< "$1"
}

run_curl() {
  local label="$1"; shift
  step_label "$label"

  local tmpfile
  tmpfile=$(mktemp)
  local http_code
  http_code=$(curl -s -w '%{http_code}' -o "$tmpfile" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" "$@")

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $http_code):" >&2
    cat "$tmpfile" >&2
    rm -f "$tmpfile"
    exit 1
  fi

  echo "  OK (HTTP $http_code)"
  rm -f "$tmpfile"
}

warn_on_fail() {
  local label="$1"; shift
  local http_code
  http_code=$(curl -s -w '%{http_code}' -o /dev/null "$@")
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "  WARNING: $label failed (HTTP $http_code)" >&2
  fi
}

ndjson_doc_count() {
  local lines
  lines=$(wc -l < "$1" | tr -d ' ')
  echo $((lines / 2))
}

index_doc_count() {
  local resp
  resp=$(curl_es -X GET "$BASE/$1/_count" 2>/dev/null || echo '{"count":-1}')
  local body
  body=$(parse_response "$resp")
  echo "$body" | jq -r '.count // -1' 2>/dev/null || echo "-1"
}

# ---------------------------------------------------------------------------
# Group: serviceuser
# ---------------------------------------------------------------------------

setup_serviceuser() {
  step_label "Creating service user 'adsb-automation'"

  local svc_user="adsb-automation"
  local svc_role="adsb-automation"
  local svc_pass
  svc_pass="$(openssl rand -base64 32)"

  local role_payload kibana_resource
  kibana_resource="space:${KB_SPACE:-default}"
  role_payload=$(jq -n --arg resource "$kibana_resource" '{
    cluster: ["manage", "manage_own_api_key"],
    indices: [{
      names: ["geo.shapes-world.countries-50m", "adsb*", "demos-aircraft-adsb*", "logs-opensky.state_vector-*"],
      privileges: ["create_index", "write", "read", "view_index_metadata", "manage"]
    }],
    applications: [{
      application: "kibana-.kibana",
      privileges: ["all"],
      resources: [$resource]
    }]
  }')

  # Create role
  local role_tmp role_http
  role_tmp=$(mktemp)
  role_http=$(curl -s -w '%{http_code}' -o "$role_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X PUT "$BASE/_security/role/$svc_role" \
    -H "Content-Type: application/json" \
    -d "$role_payload")

  if [[ "$role_http" == "400" || "$role_http" == "404" ]]; then
    echo "  Skipped — native roles not supported on this deployment (HTTP $role_http)"
    echo "  Workflow actions will be attributed to the .env API key owner"
    rm -f "$role_tmp"
    return 0
  elif [[ "$role_http" == "403" ]]; then
    echo "  Skipped — API key lacks manage_security privilege (HTTP 403)"
    echo "  Regenerate the API key with manage_security to enable service user creation."
    echo "  See README.md 'Generate an API Key' for the updated role descriptor."
    echo "  Continuing with the original API key."
    rm -f "$role_tmp"
    return 0
  elif [[ "$role_http" -lt 200 || "$role_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $role_http): Could not create service role." >&2
    cat "$role_tmp" >&2
    echo "  Continuing with the original API key." >&2
    rm -f "$role_tmp"
    return 0
  fi
  rm -f "$role_tmp"

  # Create user with the role
  local user_tmp user_http
  user_tmp=$(mktemp)
  user_http=$(curl -s -w '%{http_code}' -o "$user_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X PUT "$BASE/_security/user/$svc_user" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg pw "$svc_pass" --arg role "$svc_role" '{
      password: $pw,
      full_name: "ADS-B Automation",
      email: "adsb-automation@noreply.local",
      roles: [$role]
    }')")

  if [[ "$user_http" -lt 200 || "$user_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $user_http): Could not create service user." >&2
    cat "$user_tmp" >&2
    echo "  Continuing with the original API key." >&2
    rm -f "$user_tmp"
    return 0
  fi
  rm -f "$user_tmp"

  # Avoid accumulating a new session key on every idempotent setup run.
  local invalidate_tmp invalidate_http
  invalidate_tmp=$(mktemp)
  invalidate_http=$(curl -s -w '%{http_code}' -o "$invalidate_tmp" \
    -u "${svc_user}:${svc_pass}" \
    -X DELETE "$BASE/_security/api_key" \
    -H "Content-Type: application/json" \
    -d '{"name": "adsb-automation-session", "owner": true}')
  if [[ "$invalidate_http" -lt 200 || "$invalidate_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $invalidate_http): Could not invalidate the previous automation session key." >&2
    cat "$invalidate_tmp" >&2
  fi
  rm -f "$invalidate_tmp"

  # Mint API key as the service user (inherits role privileges)
  local key_tmp key_http
  key_tmp=$(mktemp)
  key_http=$(curl -s -w '%{http_code}' -o "$key_tmp" \
    -u "${svc_user}:${svc_pass}" \
    -X POST "$BASE/_security/api_key" \
    -H "Content-Type: application/json" \
    -d '{"name": "adsb-automation-session"}')

  if [[ "$key_http" -lt 200 || "$key_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $key_http): Could not mint API key for service user." >&2
    cat "$key_tmp" >&2
    echo "  Continuing with the original API key." >&2
    rm -f "$key_tmp"
    return 0
  fi

  local new_encoded
  new_encoded=$(jq -r '.encoded // empty' < "$key_tmp" 2>/dev/null)
  rm -f "$key_tmp"

  if [[ -z "$new_encoded" ]]; then
    echo "  WARNING: API key response missing 'encoded' field." >&2
    echo "  Continuing with the original API key." >&2
    return 0
  fi

  ES_API_KEY_ENCODED="$new_encoded"
  echo "  Using service user 'adsb-automation' for all subsequent operations"
}

setup_ingestkey() {
  step_label "Creating least-privilege ingest API key"

  local key_tmp key_http
  key_tmp=$(mktemp)
  key_http=$(curl -s -w '%{http_code}' -o "$key_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$BASE/_security/api_key" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "adsb-ingest",
      "role_descriptors": {
        "adsb_ingest": {
          "cluster": ["monitor"],
          "indices": [{
            "names": ["demos-aircraft-adsb*"],
            "privileges": ["auto_configure", "create_doc", "view_index_metadata"]
          }]
        }
      }
    }')

  if [[ "$key_http" -lt 200 || "$key_http" -ge 300 ]]; then
    echo "  FAILED (HTTP $key_http):" >&2
    cat "$key_tmp" >&2
    rm -f "$key_tmp"
    exit 1
  fi

  local key_id key_value
  key_id=$(jq -r '.id // empty' "$key_tmp")
  key_value=$(jq -r '.api_key // empty' "$key_tmp")
  rm -f "$key_tmp"
  if [[ -z "$key_id" || -z "$key_value" ]]; then
    echo "  FAILED: API key response did not contain id and api_key." >&2
    exit 1
  fi

  echo "  Created. Add these values to .env (the secret is shown only once):"
  echo "ES_INGEST_API_KEY_ID=$key_id"
  echo "ES_INGEST_API_KEY=$key_value"
}

# ---------------------------------------------------------------------------
# Group: space
# ---------------------------------------------------------------------------

setup_space() {
  if [[ -z "${KB_SPACE:-}" ]]; then
    step_label "Skipping space creation (KB_SPACE not set)"
    echo "  Using default space"
    return 0
  fi

  step_label "Creating Kibana space '${KB_SPACE}'"

  local space_check_code
  space_check_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$KB_BASE_NO_SPACE/api/spaces/space/$KB_SPACE")

  if [[ "$space_check_code" == "200" ]]; then
    echo "  Already exists — skipping"
  else
    local icon_b64=""
    local icon_file="$SCRIPT_DIR/data/adsb-space-icon-64.png"
    if [[ -f "$icon_file" ]]; then
      icon_b64=$(base64 < "$icon_file" | tr -d '\n')
    fi

    local space_payload
    space_payload=$(jq -n \
      --arg id "$KB_SPACE" \
      --arg name "ADS-B" \
      --arg desc "ADS-B flight tracking demo" \
      --arg icon "$icon_b64" \
      '{id: $id, name: $name, description: $desc, solution: "oblt", color: "#0077CC", initials: "AB"} +
       (if $icon != "" then {imageUrl: ("data:image/png;base64," + $icon)} else {} end)')

    local space_tmp space_http
    space_tmp=$(mktemp)
    space_http=$(curl -s -w '%{http_code}' -o "$space_tmp" \
      -H "Authorization: ApiKey $SETUP_API_KEY_ENCODED" \
      -X POST "$KB_BASE_NO_SPACE/api/spaces/space" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -d "$space_payload")

    if [[ "$space_http" -lt 200 || "$space_http" -ge 300 ]]; then
      echo "  WARNING (HTTP $space_http): Could not create space." >&2
      cat "$space_tmp" >&2
      echo "  Create it manually: Kibana > Stack Management > Spaces" >&2
    else
      echo "  Created (HTTP $space_http)"
    fi
    rm -f "$space_tmp"
  fi

}

# ---------------------------------------------------------------------------
# Group: ilm
# ---------------------------------------------------------------------------

setup_ilm() {
  step_label "Creating ILM policy 'adsb-lifecycle'"

  local ilm_payload_file=""
  local repo_code
  repo_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$BASE/_snapshot/found-snapshots")
  if [[ "$repo_code" != "200" ]]; then
    ilm_payload_file=$(mktemp)
    jq 'del(.policy.phases.frozen)' elasticsearch/indices/adsb-ilm-policy.json > "$ilm_payload_file"
    echo "  Searchable-snapshot repository unavailable — omitting frozen phase"
  fi

  local tmp_file http_code
  tmp_file=$(mktemp)
  http_code=$(curl -s -w '%{http_code}' -o "$tmp_file" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X PUT "$BASE/_ilm/policy/adsb-lifecycle" \
    -H "Content-Type: application/json" \
    -d "@${ilm_payload_file:-elasticsearch/indices/adsb-ilm-policy.json}")

  if [[ "$http_code" == "400" || "$http_code" == "404" ]]; then
    echo "  Skipped — ILM not available on this deployment (HTTP $http_code)"
    echo "  Data stream lifecycle (data_retention: 730d) will manage retention instead"
  elif [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $http_code):" >&2
    cat "$tmp_file" >&2
    rm -f "$tmp_file"
    exit 1
  else
    echo "  OK (HTTP $http_code)"
  fi
  rm -f "$tmp_file" "$ilm_payload_file"
}

# ---------------------------------------------------------------------------
# Group: indices
# ---------------------------------------------------------------------------

setup_index() {
  local index_name="$1" mapping_file="$2" data_file="$3" label="$4"

  step_label "Creating $label index"

  local head_code
  head_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -I "$BASE/$index_name")

  if [[ "$head_code" == "200" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Index exists — deleting (--force)"
      curl_es -X DELETE "$BASE/$index_name" > /dev/null 2>&1
      local tmpfile
      tmpfile=$(mktemp)
      local create_code
      create_code=$(curl -s -w '%{http_code}' -o "$tmpfile" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$BASE/$index_name" \
        -H "Content-Type: application/json" \
        -d "@$mapping_file")
      if [[ "$create_code" -lt 200 || "$create_code" -ge 300 ]]; then
        echo "  FAILED (HTTP $create_code):" >&2
        cat "$tmpfile" >&2
        rm -f "$tmpfile"
        exit 1
      fi
      echo "  Recreated (HTTP $create_code)"
      rm -f "$tmpfile"
    else
      echo "  Already exists — skipping creation"
    fi
  else
    local tmpfile
    tmpfile=$(mktemp)
    local create_code
    create_code=$(curl -s -w '%{http_code}' -o "$tmpfile" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$BASE/$index_name" \
      -H "Content-Type: application/json" \
      -d "@$mapping_file")
    if [[ "$create_code" -lt 200 || "$create_code" -ge 300 ]]; then
      echo "  FAILED (HTTP $create_code):" >&2
      cat "$tmpfile" >&2
      rm -f "$tmpfile"
      exit 1
    fi
    echo "  Created (HTTP $create_code)"
    rm -f "$tmpfile"
  fi

  step_label "Loading $label reference data"

  if [[ "$FORCE" == "true" ]]; then
    echo "  Loading unconditionally (--force)"
  else
    local expected actual
    expected=$(ndjson_doc_count "$data_file")
    actual=$(index_doc_count "$index_name")
    if [[ "$actual" == "$expected" ]]; then
      echo "  Reference data already loaded ($actual documents) — skipping"
      step_label "Refreshing $label index"
      echo "  Skipped (data unchanged)"
      return 0
    fi
    echo "  Document count differs (index: $actual, file: $expected) — reloading"
    local delete_tmp delete_code
    delete_tmp=$(mktemp)
    delete_code=$(curl -s -w '%{http_code}' -o "$delete_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$BASE/$index_name/_delete_by_query?conflicts=proceed&refresh=true" \
      -H "Content-Type: application/json" \
      -d '{"query":{"match_all":{}}}')
    if [[ "$delete_code" -lt 200 || "$delete_code" -ge 300 ]]; then
      echo "  FAILED to clear stale reference data (HTTP $delete_code):" >&2
      cat "$delete_tmp" >&2
      rm -f "$delete_tmp"
      exit 1
    fi
    rm -f "$delete_tmp"
  fi

  local bulk_data_file="$data_file" generated_bulk_file=""
  if [[ "$index_name" == "adsb-airports-geo" ]]; then
    generated_bulk_file=$(mktemp)
    jq -cn --arg index "$index_name" '
      foreach inputs as $line (
        {line: 0};
        .line += 1
        | if (.line % 2) == 1 then .action = $line else .document = $line end;
        if (.line % 2) == 0 then
          {"index": {
            "_index": $index,
            "_id": (
              .document.ne_id
              // .document.gps_code
              // .document.iata_code
              | tostring
            )
          }},
          .document
        else empty end
      )
    ' "$data_file" > "$generated_bulk_file"
    bulk_data_file="$generated_bulk_file"
  fi

  local bulk_tmp bulk_code
  bulk_tmp=$(mktemp)
  bulk_code=$(curl -s -w '%{http_code}' -o "$bulk_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$BASE/$index_name/_bulk" \
    -H "Content-Type: application/x-ndjson" \
    --data-binary "@$bulk_data_file")

  if [[ "$bulk_code" -lt 200 || "$bulk_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $bulk_code):" >&2
    cat "$bulk_tmp" >&2
    rm -f "$bulk_tmp" "$generated_bulk_file"
    exit 1
  fi
  if jq -e '.errors == true' "$bulk_tmp" >/dev/null 2>&1; then
    echo "  FAILED: bulk request contained item errors:" >&2
    jq -r '
      [.items[] | to_entries[] | select(.value.error) |
       "\(.key) \(.value._id // "?"): \(.value.status) \(.value.error.type): \(.value.error.reason)"]
      | .[:10][]
    ' "$bulk_tmp" >&2
    rm -f "$bulk_tmp" "$generated_bulk_file"
    exit 1
  fi
  echo "  OK (HTTP $bulk_code) — $(jq -r '.items | length' "$bulk_tmp") documents indexed"
  rm -f "$bulk_tmp" "$generated_bulk_file"

  step_label "Refreshing $label index"
  local ref_tmp ref_code
  ref_tmp=$(mktemp)
  ref_code=$(curl -s -w '%{http_code}' -o "$ref_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$BASE/$index_name/_refresh")
  if [[ "$ref_code" -lt 200 || "$ref_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $ref_code):" >&2
    cat "$ref_tmp" >&2
    rm -f "$ref_tmp"
    exit 1
  fi
  echo "  OK (HTTP $ref_code)"
  rm -f "$ref_tmp"
}

setup_indices() {
  setup_index \
    "geo.shapes-world.countries-50m" \
    "elasticsearch/indices/geo-shapes-world-countries-50m-mapping.json" \
    "data/geo-shapes-world-countries-50m-data.json" \
    "geo shapes"

  setup_index \
    "adsb-airports-geo" \
    "elasticsearch/indices/adsb-airports-geo-mapping.json" \
    "data/adsb-airports-geo-data.ndjson" \
    "airports"

  setup_index \
    "adsb-airlines-defunct" \
    "elasticsearch/indices/adsb-airlines-defunct-mapping.json" \
    "data/adsb-airlines-defunct-data.ndjson" \
    "defunct airlines"
}

# ---------------------------------------------------------------------------
# Group: enrich
# ---------------------------------------------------------------------------

exec_enrich_policy() {
  local policy_name="$1"
  local exec_tmp exec_code
  exec_tmp=$(mktemp)
  exec_code=$(curl -s -w '%{http_code}' -o "$exec_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$BASE/_enrich/policy/$policy_name/_execute")
  if [[ "$exec_code" -lt 200 || "$exec_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $exec_code):" >&2
    cat "$exec_tmp" >&2
    rm -f "$exec_tmp"
    exit 1
  fi
  echo "  OK (HTTP $exec_code)"
  rm -f "$exec_tmp"
}

setup_enrich_policy() {
  local policy_name="$1" policy_file="$2" label="$3"

  step_label "Creating $label enrich policy"

  local check_resp check_code check_body policy_exists=false
  check_resp=$(curl_es -X GET "$BASE/_enrich/policy/$policy_name" 2>/dev/null)
  check_code=$(http_code_of "$check_resp")
  check_body=$(parse_response "$check_resp")
  if [[ "$check_code" == "200" ]]; then
    local policy_count
    policy_count=$(echo "$check_body" | jq -r '.policies | length' 2>/dev/null || echo "0")
    [[ "$policy_count" -gt 0 ]] && policy_exists=true
  fi

  if [[ "$policy_exists" == "true" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Policy exists — attempting delete (--force)"
      local del_tmp del_code
      del_tmp=$(mktemp)
      del_code=$(curl -s -w '%{http_code}' -o "$del_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X DELETE "$BASE/_enrich/policy/$policy_name")
      if [[ "$del_code" -ge 200 && "$del_code" -lt 300 ]]; then
        echo "  Deleted — recreating"
        rm -f "$del_tmp"
      else
        echo "  Could not delete (HTTP $del_code, likely referenced by a pipeline) — re-executing instead"
        rm -f "$del_tmp"
        step_label "Executing $label enrich policy"
        exec_enrich_policy "$policy_name"
        return 0
      fi
    else
      echo "  Already exists — skipping creation"
    fi
  fi

  if [[ "$policy_exists" != "true" ]] || [[ "$FORCE" == "true" ]]; then
    local tmp_file create_code
    tmp_file=$(mktemp)
    create_code=$(curl -s -w '%{http_code}' -o "$tmp_file" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$BASE/_enrich/policy/$policy_name" \
      -H "Content-Type: application/json" \
      -d "@$policy_file")

    if [[ "$create_code" -lt 200 || "$create_code" -ge 300 ]]; then
      echo "  FAILED (HTTP $create_code):" >&2
      cat "$tmp_file" >&2
      rm -f "$tmp_file"
      exit 1
    fi
    echo "  OK (HTTP $create_code)"
    rm -f "$tmp_file"
  fi

  step_label "Executing $label enrich policy"
  exec_enrich_policy "$policy_name"
}

setup_enrich() {
  setup_enrich_policy \
    "opensky-geo-enrich-50m" \
    "elasticsearch/enrich/adsb-geo-enrich-policy.json" \
    "geo-shape"

  setup_enrich_policy \
    "adsb-airport-proximity" \
    "elasticsearch/enrich/adsb-airport-enrich-policy.json" \
    "airport coverage zone"
}

setup_opensky_integration_compat() {
  local data_stream="${OPENSKY_INTEGRATION_DATA_STREAM:-logs-opensky.state_vector-default}"
  local custom_component="logs-opensky.state_vector@custom"
  local custom_pipeline="logs-opensky.state_vector@custom"
  local canonical_alias="demos-aircraft-adsb"
  local integration_namespace=""
  local alias_exists=false

  if [[ "$data_stream" == logs-opensky.state_vector-* ]]; then
    integration_namespace="${data_stream#logs-opensky.state_vector-}"
  fi
  if [[ -z "$integration_namespace" ]]; then
    echo "ERROR: OPENSKY_INTEGRATION_DATA_STREAM must match logs-opensky.state_vector-<namespace>." >&2
    exit 1
  fi

  step_label "Verifying OpenSky integration data stream '$data_stream'"
  local check_tmp check_http
  check_tmp=$(mktemp)
  check_http=$(curl -s -w '%{http_code}' -o "$check_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$BASE/_data_stream/$data_stream")
  if [[ "$check_http" != "200" ]]; then
    echo "  FAILED: OpenSky integration data stream '$data_stream' was not found." >&2
    echo "  Install the OpenSky integration and wait for its first state-vector poll, or set OPENSKY_INTEGRATION_DATA_STREAM." >&2
    cat "$check_tmp" >&2
    rm -f "$check_tmp"
    exit 1
  fi
  rm -f "$check_tmp"
  echo "  Found"

  check_tmp=$(mktemp)
  check_http=$(curl -s -w '%{http_code}' -o "$check_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$BASE/_index_template/logs-opensky.state_vector")
  if [[ "$check_http" != "200" ]] || ! jq -e --arg component "$custom_component" \
    '.index_templates[0].index_template.composed_of | index($component)' \
    "$check_tmp" >/dev/null; then
    echo "  FAILED: the installed OpenSky package does not expose the expected '$custom_component' extension point." >&2
    echo "  Upgrade the OpenSky integration before enabling compatibility mode." >&2
    cat "$check_tmp" >&2
    rm -f "$check_tmp"
    exit 1
  fi
  rm -f "$check_tmp"

  check_tmp=$(mktemp)
  check_http=$(curl -s -w '%{http_code}' -o "$check_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$BASE/$data_stream/_field_caps?fields=host.id,host.geo.location,opensky.state_vector.callsign,opensky.state_vector.squawk")
  if [[ "$check_http" != "200" ]] || ! jq -e '
    .fields["host.id"]
    and .fields["host.geo.location"]
    and .fields["opensky.state_vector.callsign"]
    and .fields["opensky.state_vector.squawk"]
  ' "$check_tmp" >/dev/null; then
    echo "  FAILED: '$data_stream' does not expose the OpenSky state-vector field contract." >&2
    cat "$check_tmp" >&2
    rm -f "$check_tmp"
    exit 1
  fi
  rm -f "$check_tmp"

  # Preflight the canonical alias before mutating any Fleet resources.
  local alias_tmp alias_http
  alias_tmp=$(mktemp)
  alias_http=$(curl -s -w '%{http_code}' -o "$alias_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$BASE/_alias/$canonical_alias")
  if [[ "$alias_http" == "200" ]]; then
    if ! jq -e --arg stream "$data_stream" --arg alias "$canonical_alias" '
      keys == [$stream] and .[$stream].aliases[$alias] != null
    ' "$alias_tmp" >/dev/null; then
      echo "  FAILED: data stream alias '$canonical_alias' must target only '$data_stream'." >&2
      cat "$alias_tmp" >&2
      rm -f "$alias_tmp"
      exit 1
    fi
    alias_exists=true
  elif [[ "$alias_http" == "404" ]]; then
    local conflict_http
    conflict_http=$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      "$BASE/_data_stream/$canonical_alias")
    if [[ "$conflict_http" == "200" ]]; then
      echo "  FAILED: '$canonical_alias' is already a standalone data stream and cannot also be an alias." >&2
      echo "  Use a clean deployment or continue with INGEST_ENGINE=agent/logstash." >&2
      rm -f "$alias_tmp"
      exit 1
    fi
  else
    echo "  FAILED (HTTP $alias_http): Could not inspect data stream aliases." >&2
    cat "$alias_tmp" >&2
    rm -f "$alias_tmp"
    exit 1
  fi
  rm -f "$alias_tmp"

  run_curl "Creating OpenSky integration compatibility pipeline" \
    -X PUT "$BASE/_ingest/pipeline/demo-aircraft-adsb.opensky-compat" \
    -H "Content-Type: application/json" \
    -d @elasticsearch/pipelines/opensky-integration-compat-pipeline.json

  local component_tmp component_http component_payload
  component_tmp=$(mktemp)
  component_http=$(curl -s -w '%{http_code}' -o "$component_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$BASE/_component_template/$custom_component")
  component_payload=$(mktemp)
  if [[ "$component_http" == "200" ]]; then
    jq --slurpfile compat elasticsearch/indices/opensky-integration-compat-component-template.json \
      '.component_templates[0].component_template * $compat[0]' \
      "$component_tmp" > "$component_payload"
  elif [[ "$component_http" == "404" ]]; then
    cp elasticsearch/indices/opensky-integration-compat-component-template.json "$component_payload"
  else
    echo "  FAILED (HTTP $component_http): Could not inspect $custom_component." >&2
    cat "$component_tmp" >&2
    rm -f "$component_tmp" "$component_payload"
    exit 1
  fi
  rm -f "$component_tmp"

  run_curl "Configuring the OpenSky integration custom component" \
    -X PUT "$BASE/_component_template/$custom_component" \
    -H "Content-Type: application/json" \
    -d "@$component_payload"
  rm -f "$component_payload"

  local mappings_tmp
  mappings_tmp=$(mktemp)
  jq '.template.mappings' \
    elasticsearch/indices/opensky-integration-compat-component-template.json > "$mappings_tmp"
  run_curl "Adding demo-compatible fields to the OpenSky data stream" \
    -X PUT "$BASE/$data_stream/_mapping" \
    -H "Content-Type: application/json" \
    -d "@$mappings_tmp"
  rm -f "$mappings_tmp"

  local custom_pipeline_tmp custom_pipeline_http custom_pipeline_payload
  custom_pipeline_tmp=$(mktemp)
  custom_pipeline_payload=$(mktemp)
  custom_pipeline_http=$(curl -s -w '%{http_code}' -o "$custom_pipeline_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$BASE/_ingest/pipeline/$custom_pipeline")
  if [[ "$custom_pipeline_http" == "200" ]]; then
    jq --arg name "$custom_pipeline" \
      --arg condition "ctx.data_stream?.namespace == '$integration_namespace'" '
      .[$name]
      | .processors //= []
      | .processors = [
          .processors[]?
          | select(.pipeline?.name != "demo-aircraft-adsb.opensky-compat")
        ] + [{
          pipeline: {
            name: "demo-aircraft-adsb.opensky-compat",
            tag: "adsb_demo_compatibility",
            if: $condition
          }
        }]
    ' "$custom_pipeline_tmp" > "$custom_pipeline_payload"
  elif [[ "$custom_pipeline_http" == "404" ]]; then
    jq -n --arg condition "ctx.data_stream?.namespace == '$integration_namespace'" '{
      description: "OpenSky integration custom processing for ADS-B demo compatibility.",
      processors: [{
        pipeline: {
          name: "demo-aircraft-adsb.opensky-compat",
          tag: "adsb_demo_compatibility",
          if: $condition
        }
      }]
    }' > "$custom_pipeline_payload"
  else
    echo "  FAILED (HTTP $custom_pipeline_http): Could not inspect $custom_pipeline." >&2
    cat "$custom_pipeline_tmp" >&2
    rm -f "$custom_pipeline_tmp" "$custom_pipeline_payload"
    exit 1
  fi
  rm -f "$custom_pipeline_tmp"

  run_curl "Connecting compatibility processing to the OpenSky integration" \
    -X PUT "$BASE/_ingest/pipeline/$custom_pipeline" \
    -H "Content-Type: application/json" \
    -d "@$custom_pipeline_payload"
  rm -f "$custom_pipeline_payload"

  if [[ "$alias_exists" == "true" ]]; then
    step_label "Configuring the canonical ADS-B data stream alias"
    echo "  Already targets $data_stream — skipping"
  else
    run_curl "Configuring the canonical ADS-B data stream alias" \
      -X POST "$BASE/_data_stream/_modify" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg stream "$data_stream" --arg alias "$canonical_alias" \
        '{actions: [{add: {data_stream: $stream, alias: $alias}}]}')"
  fi
}

prepare_local_ingest_target() {
  local canonical_alias="demos-aircraft-adsb"
  local alias_tmp alias_http alias_stream
  alias_tmp=$(mktemp)
  alias_http=$(curl -s -w '%{http_code}' -o "$alias_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$BASE/_alias/$canonical_alias")

  if [[ "$alias_http" == "404" ]]; then
    rm -f "$alias_tmp"
    return 0
  fi
  if [[ "$alias_http" != "200" ]]; then
    echo "  FAILED (HTTP $alias_http): Could not inspect data stream aliases." >&2
    cat "$alias_tmp" >&2
    rm -f "$alias_tmp"
    exit 1
  fi

  alias_stream=$(jq -r --arg alias "$canonical_alias" '
    [
      to_entries[]
      | select(.value.aliases[$alias] != null)
      | .key
    ]
    | if length == 1 then .[0] else empty end
  ' "$alias_tmp")
  rm -f "$alias_tmp"
  if [[ "$alias_stream" != logs-opensky.state_vector-* ]]; then
    echo "  FAILED: '$canonical_alias' is a data stream alias not managed by OpenSky compatibility mode." >&2
    echo "  Remove or rename it before enabling local Agent/Logstash ingest." >&2
    exit 1
  fi

  run_curl "Restoring the canonical ADS-B target for local ingest" \
    -X POST "$BASE/_data_stream/_modify" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg stream "$alias_stream" --arg alias "$canonical_alias" \
      '{actions: [{remove: {data_stream: $stream, alias: $alias}}]}')"
}

# ---------------------------------------------------------------------------
# Group: pipelines
# ---------------------------------------------------------------------------

setup_pipelines() {
  run_curl "Creating ingest pipeline" \
    -X PUT "$BASE/_ingest/pipeline/demo-aircraft-adsb.opensky" \
    -H "Content-Type: application/json" \
    -d @elasticsearch/pipelines/adsb-ingest-pipeline.json

  local template_payload="elasticsearch/indices/adsb-index-template.json"
  local generated_template=""
  if [[ -n "${DLM_FROZEN_AFTER:-}" ]]; then
    local license_type repository_count
    license_type=$(curl -s \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      "$BASE/_license" | jq -r '.license.type // empty' 2>/dev/null || true)
    repository_count=$(curl -s \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      "$BASE/_snapshot/_all" | jq 'if type == "object" and (.error | not) then length else 0 end' 2>/dev/null || echo 0)
    if [[ "$license_type" =~ ^(enterprise|trial)$ && "$repository_count" -gt 0 ]]; then
      generated_template=$(mktemp)
      jq --arg frozen_after "$DLM_FROZEN_AFTER" \
        '.template.lifecycle.frozen_after = $frozen_after' \
        "$template_payload" > "$generated_template"
      template_payload="$generated_template"
      echo "  Enabling DLM frozen transition after $DLM_FROZEN_AFTER"
    else
      echo "  DLM frozen transition skipped — Enterprise licence and a snapshot repository are required"
    fi
  fi
  run_curl "Creating index template" \
    -X PUT "$BASE/_index_template/demos-aircraft-adsb" \
    -H "Content-Type: application/json" \
    -d "@$template_payload"
  rm -f "$generated_template"

  local historical_settings="elasticsearch/indices/adsb-historical-import-cluster-settings.json"
  local historical_tmp historical_http
  historical_tmp=$(mktemp)
  if [[ "${ENABLE_HISTORICAL_TSDS_IMPORT:-false}" == "true" ]]; then
    if [[ -f "$historical_settings" ]]; then
      historical_http=$(curl -s -w '%{http_code}' -o "$historical_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -H "Content-Type: application/json" \
        -X PUT "$BASE/_cluster/settings" \
        -d "@$historical_settings")
      if [[ "$historical_http" -ge 200 && "$historical_http" -lt 300 ]]; then
        echo "  Historical TSDS import window enabled (cluster-wide opt-in)"
      else
        echo "  WARNING (HTTP $historical_http): Historical TSDS import is unsupported on this deployment." >&2
        cat "$historical_tmp" >&2
      fi
    else
      echo "  WARNING: Historical TSDS settings asset is not present — skipping." >&2
    fi
  else
    historical_http=$(curl -s -w '%{http_code}' -o "$historical_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -H "Content-Type: application/json" \
      -X PUT "$BASE/_cluster/settings" \
      -d '{"persistent":{"data_stream.past_tsdb_index_creation_enabled":null,"data_streams.past_tsdb_index_interval":null}}')
    if [[ "$historical_http" -ge 200 && "$historical_http" -lt 300 ]]; then
      echo "  Historical TSDS import window disabled"
    else
      echo "  Historical TSDS import setting unavailable on this deployment (HTTP $historical_http)"
    fi
  fi
  rm -f "$historical_tmp"

  if [[ "${INGEST_ENGINE:-agent}" == "opensky_integration" ]]; then
    setup_opensky_integration_compat
  else
    prepare_local_ingest_target
  fi
}

# ---------------------------------------------------------------------------
# Group: kibana
# ---------------------------------------------------------------------------

setup_kibana() {
  STEP=$((STEP + 1))

  local overwrite_param=""
  if [[ "$FORCE" == "true" ]]; then
    overwrite_param="?overwrite=true"
    echo "[$STEP/$TOTAL] Importing Kibana saved objects (--force: overwriting existing) ..."
  else
    echo "[$STEP/$TOTAL] Importing Kibana saved objects ..."
  fi

  local import_tmp import_http
  import_tmp=$(mktemp)
  import_http=$(curl -s -w '%{http_code}' -o "$import_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/saved_objects/_import${overwrite_param}" \
    -H "kbn-xsrf: true" \
    -F "file=@elasticsearch/kibana/adsb-saved-objects.ndjson")

  if [[ "$import_http" -lt 200 || "$import_http" -ge 300 ]]; then
    echo "  FAILED (HTTP $import_http):" >&2
    cat "$import_tmp" >&2
    rm -f "$import_tmp"
    exit 1
  fi

  local import_success
  import_success=$(jq -r '.success // true' < "$import_tmp" || echo "true")

  if [[ "$import_success" == "false" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  PARTIAL FAILURE (HTTP $import_http):" >&2
      jq -r '
        "  \(.successCount // 0) objects imported, \(.errors // [] | length) failed:",
        (.errors // [] | .[] |
          "    - \(.type) \"\(.meta.title // "?")\": \(.error.type // "?") (refs: \(.error.references // [] | [.[].id // "?"] | join(", ")))")
      ' < "$import_tmp" >&2
      rm -f "$import_tmp"
      exit 1
    else
      local ok_count skipped_count
      ok_count=$(jq -r '.successCount // 0' < "$import_tmp" 2>/dev/null || echo "0")
      skipped_count=$(jq -r '.errors // [] | length' < "$import_tmp" 2>/dev/null || echo "0")
      echo "  OK (HTTP $import_http) — $ok_count imported, $skipped_count skipped (already exist)"
    fi
  else
    echo "  OK (HTTP $import_http) — $(jq -r '.successCount // "?"' < "$import_tmp" || echo "?") objects imported"
  fi

  rm -f "$import_tmp"

  step_label "Deploying ADS-B operations dashboard as code"
  local dashboard_id="adsb-operations-cases"
  local dashboard_file="elasticsearch/kibana/adsb-operations-dashboard.json"
  local dashboard_tmp dashboard_http dashboard_payload case_space_id
  case_space_id="${KB_SPACE:-default}"
  dashboard_payload=$(sed "s|__KB_SPACE_ID__|${case_space_id}|g" "$dashboard_file")
  dashboard_tmp=$(mktemp)
  dashboard_http=$(curl -s -w '%{http_code}' -o "$dashboard_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -X PUT "$KB_BASE/api/dashboards/$dashboard_id" \
    -d "$dashboard_payload")
  if [[ "$dashboard_http" -ge 200 && "$dashboard_http" -lt 300 ]]; then
    echo "  OK (HTTP $dashboard_http) — dashboard ID: $dashboard_id"
  elif [[ "$dashboard_http" == "404" ]]; then
    echo "  Skipped — the Dashboards API requires Kibana 9.5+"
  else
    echo "  FAILED (HTTP $dashboard_http):" >&2
    cat "$dashboard_tmp" >&2
    rm -f "$dashboard_tmp"
    exit 1
  fi
  rm -f "$dashboard_tmp"
}

# ---------------------------------------------------------------------------
# Group: cases
# ---------------------------------------------------------------------------

setup_cases() {
  step_label "Configuring case custom fields and templates"

  local fields_file="elasticsearch/cases/field-definitions.json"
  local field_count field_index field_tmp field_http
  field_count=$(jq 'length' "$fields_file")
  for ((field_index = 0; field_index < field_count; field_index++)); do
    field_tmp=$(mktemp)
    field_http=$(curl -s -w '%{http_code}' -o "$field_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X POST "$KB_BASE/api/cases/field_definitions" \
      -d "$(jq -c ".[$field_index]" "$fields_file")")
    if [[ "$field_http" -ge 200 && "$field_http" -lt 300 ]]; then
      echo "  Created Case field: $(jq -r ".[$field_index].name" "$fields_file")"
    elif [[ "$field_http" == "409" ]]; then
      echo "  Case field already exists: $(jq -r ".[$field_index].name" "$fields_file")"
    elif [[ "$field_http" == "404" ]]; then
      echo "  Case field library unavailable on this deployment — using legacy custom fields"
      rm -f "$field_tmp"
      break
    else
      echo "  WARNING (HTTP $field_http): Could not create Case field definition." >&2
      cat "$field_tmp" >&2
    fi
    rm -f "$field_tmp"
  done

  local config_file="elasticsearch/cases/observability-config.json"

  # Check for existing case configuration for the observability owner
  local cfg_tmp cfg_http
  cfg_tmp=$(mktemp)
  cfg_http=$(curl -s -w '%{http_code}' -o "$cfg_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" \
    -X GET "$KB_BASE/api/cases/configure?owner=observability")

  if [[ "$cfg_http" -lt 200 || "$cfg_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $cfg_http): Could not query case configuration." >&2
    cat "$cfg_tmp" >&2
    rm -f "$cfg_tmp"
    return 0
  fi

  local existing_id existing_version
  existing_id=$(jq -r '.[0].id // empty' < "$cfg_tmp" 2>/dev/null || true)
  existing_version=$(jq -r '.[0].version // empty' < "$cfg_tmp" 2>/dev/null || true)

  if [[ -n "$existing_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Configuration exists — updating (--force)"
      local patch_payload
      patch_payload=$(jq --arg ver "$existing_version" '{
        version: $ver,
        customFields: .customFields,
        templates: .templates
      }' "$config_file")

      local patch_tmp patch_http
      patch_tmp=$(mktemp)
      patch_http=$(curl -s -w '%{http_code}' -o "$patch_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -X PATCH "$KB_BASE/api/cases/configure/$existing_id" \
        -d "$patch_payload")

      if [[ "$patch_http" -lt 200 || "$patch_http" -ge 300 ]]; then
        echo "  WARNING (HTTP $patch_http): Could not update case configuration." >&2
        cat "$patch_tmp" >&2
      else
        echo "  Updated (HTTP $patch_http)"
      fi
      rm -f "$patch_tmp"
    else
      echo "  Already exists — skipping"
    fi
  else
    echo "  Creating case configuration ..."
    local create_tmp create_http
    create_tmp=$(mktemp)
    create_http=$(curl -s -w '%{http_code}' -o "$create_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X POST "$KB_BASE/api/cases/configure" \
      -d "@$config_file")

    if [[ "$create_http" -lt 200 || "$create_http" -ge 300 ]]; then
      echo "  WARNING (HTTP $create_http): Could not create case configuration." >&2
      cat "$create_tmp" >&2
      echo "  Configure it manually in Kibana > Cases > Settings." >&2
    else
      echo "  Created (HTTP $create_http)"
    fi
    rm -f "$create_tmp"
  fi

  rm -f "$cfg_tmp"
}

# ---------------------------------------------------------------------------
# Group: agents
# ---------------------------------------------------------------------------

deploy_agent() {
  local agent_id="$1" agent_file="$2" label="$3" always_update="${4:-false}"

  step_label "Deploying $label"

  # Strip id from the body — the API rejects it on PUT, and on POST the script
  # injects it explicitly so that the agent_id argument is the canonical source.
  local agent_body_no_id
  agent_body_no_id=$(jq 'del(.id)' "$agent_file")

  if [[ "$FORCE" == "true" || "$always_update" == "true" ]]; then
    local agent_tmp agent_http
    agent_tmp=$(mktemp)
    agent_http=$(curl -s -w '%{http_code}' -o "$agent_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$KB_BASE/api/agent_builder/agents/$agent_id" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -d "$agent_body_no_id")

    if [[ "$agent_http" == "404" ]]; then
      agent_http=$(curl -s -w '%{http_code}' -o "$agent_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X POST "$KB_BASE/api/agent_builder/agents" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d "$(echo "$agent_body_no_id" | jq --arg id "$agent_id" '. + {id: $id}')")
    fi

    if [[ "$agent_http" -lt 200 || "$agent_http" -ge 300 ]]; then
      echo "  FAILED (HTTP $agent_http):" >&2
      cat "$agent_tmp" >&2
      rm -f "$agent_tmp"
      exit 1
    fi
    echo "  OK (HTTP $agent_http)"
    rm -f "$agent_tmp"
  else
    local agent_tmp agent_http
    agent_tmp=$(mktemp)
    agent_http=$(curl -s -w '%{http_code}' -o "$agent_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/agent_builder/agents" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -d "$(echo "$agent_body_no_id" | jq --arg id "$agent_id" '. + {id: $id}')")

    if [[ "$agent_http" -ge 200 && "$agent_http" -lt 300 ]]; then
      echo "  Created (HTTP $agent_http)"
    elif [[ "$agent_http" == "409" ]] || { [[ "$agent_http" == "400" ]] && grep -q "already exists" "$agent_tmp"; }; then
      echo "  Already exists — skipping"
    else
      echo "  FAILED (HTTP $agent_http):" >&2
      cat "$agent_tmp" >&2
      rm -f "$agent_tmp"
      exit 1
    fi
    rm -f "$agent_tmp"
  fi
}

setup_agents() {
  # Extract dashboard IDs for agent instruction placeholders
  local DASHBOARD_AIRCRAFT_DETAIL_ID DASHBOARD_WORLD_OVERVIEW_ID
  DASHBOARD_AIRCRAFT_DETAIL_ID=$(jq -r \
    'select(.type == "dashboard" and .attributes.title == "Aircraft Detail") | .id' \
    elasticsearch/kibana/adsb-saved-objects.ndjson | head -1)
  DASHBOARD_WORLD_OVERVIEW_ID=$(jq -r \
    'select(.type == "dashboard" and .attributes.title == "Aircraft World Overview") | .id' \
    elasticsearch/kibana/adsb-saved-objects.ndjson | head -1)

  # ADS-B agent needs KB_ENDPOINT and dashboard IDs substituted into instructions
  local adsb_agent_tmp
  adsb_agent_tmp=$(mktemp)
  sed -e "s|__KB_ENDPOINT__|${KB_BASE}|g" \
      -e "s|__DASHBOARD_AIRCRAFT_DETAIL_ID__|${DASHBOARD_AIRCRAFT_DETAIL_ID}|g" \
      -e "s|__DASHBOARD_WORLD_OVERVIEW_ID__|${DASHBOARD_WORLD_OVERVIEW_ID}|g" \
      "elasticsearch/agents/adsb-agent.json" > "$adsb_agent_tmp"

  deploy_agent \
    "adsb_agent" \
    "$adsb_agent_tmp" \
    "ADS-B tracking agent"
  rm -f "$adsb_agent_tmp"

  deploy_agent \
    "adsb_daily_briefing_agent" \
    "elasticsearch/agents/adsb-daily-briefing-agent.json" \
    "daily briefing agent"

  deploy_agent \
    "adsb_hijack_assessment_agent" \
    "elasticsearch/agents/adsb-hijack-assessment-agent.json" \
    "hijack assessment agent" \
    "true"

  if [[ -n "${HIJACK_AGENT_ALLOWED_USERS:-}${HIJACK_AGENT_EDITORS:-}${HIJACK_AGENT_MANAGERS:-}" ]]; then
    step_label "Restricting hijack assessment agent access"
    local acl_entries acl_tmp acl_http
    acl_entries=$(jq -n \
      --arg users "${HIJACK_AGENT_ALLOWED_USERS:-}" \
      --arg editors "${HIJACK_AGENT_EDITORS:-}" \
      --arg managers "${HIJACK_AGENT_MANAGERS:-}" '
      def entries($names; $role):
        $names
        | split(",")
        | map(gsub("^\\s+|\\s+$"; ""))
        | map(select(length > 0))
        | map({type: "user", name: ., role: $role});
      entries($users; "user")
      + entries($editors; "editor")
      + entries($managers; "manager")
    ')
    acl_tmp=$(mktemp)
    acl_http=$(curl -s -w '%{http_code}' -o "$acl_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X PUT "$KB_BASE/api/agent_builder/agents/adsb_hijack_assessment_agent/access_control" \
      -d "$(jq -n --argjson entries "$acl_entries" '{entries: $entries}')")
    if [[ "$acl_http" -ge 200 && "$acl_http" -lt 300 ]]; then
      echo "  Private access configured for $(jq 'length' <<< "$acl_entries") user(s)"
    elif [[ "$acl_http" == "404" ]]; then
      echo "  Skipped — per-agent access control requires Kibana 9.5+"
    else
      echo "  WARNING (HTTP $acl_http): Could not configure agent access control." >&2
      cat "$acl_tmp" >&2
    fi
    rm -f "$acl_tmp"
  fi
}

# ---------------------------------------------------------------------------
# Group: workflows
# ---------------------------------------------------------------------------

prepare_workflow() {
  local workflow_id="$1" workflow_name="$2" workflow_file="$3"
  local dashboard_world_id="$4" dashboard_detail_id="$5"
  local space_prefix="$6" gnews_connector_id="$7"

  step_label "Preparing $workflow_name workflow"

  local yaml_content
  yaml_content=$(sed \
    -e "s|__KB_ENDPOINT__|${KB_BASE}|g" \
    -e "s|__SPACE_PREFIX__|${space_prefix}|g" \
    -e "s|__SLACK_CONNECTOR_ID__|${SLACK_CONNECTOR_ID:-d85ca362-fb82-56f6-867c-4ef2c356d912}|g" \
    -e "s|__DASHBOARD_WORLD_OVERVIEW_ID__|${dashboard_world_id}|g" \
    -e "s|__DASHBOARD_AIRCRAFT_DETAIL_ID__|${dashboard_detail_id}|g" \
    -e 's|&apikey=__GNEWS_API_KEY__||g' \
    "$workflow_file")

  if [[ -n "$gnews_connector_id" ]] && grep -q 'gnews.io/api/v4/search' <<< "$yaml_content"; then
    yaml_content=$(awk -v connector_id="$gnews_connector_id" '
      /- name: news_search/ { in_news = 1 }
      in_news && /^[[:space:]]*type: http$/ {
        print
        match($0, /^[[:space:]]*/)
        indent = substr($0, 1, RLENGTH)
        print indent "connector-id: \"" connector_id "\""
        next
      }
      in_news && /url: "https:\/\/gnews.io\/api\/v4\/search/ {
        match($0, /^[[:space:]]*/)
        indent = substr($0, 1, RLENGTH)
        print indent "path: \"/api/v4/search\""
        print indent "query:"
        if ($0 ~ /inputs.callsign/) {
          print indent "  q: \"{{ inputs.callsign }} hijack\""
        } else {
          print indent "  q: \"{{ event.alerts[0].kibana.alert.grouping.callsign }} hijack\""
        }
        print indent "  max: \"5\""
        next
      }
      in_news && /^[[:space:]]*on-failure:/ { in_news = 0 }
      { print }
    ' <<< "$yaml_content")
  fi

  WORKFLOW_BULK_PAYLOAD=$(jq \
    --arg id "$workflow_id" --arg yaml "$yaml_content" \
    '.workflows += [{id: $id, yaml: $yaml}]' \
    <<< "$WORKFLOW_BULK_PAYLOAD")
}

deploy_workflow_batch() {
  step_label "Deploying source-controlled workflows"

  local payload="$WORKFLOW_BULK_PAYLOAD" tmp http existing_ids
  tmp=$(mktemp)

  if [[ "$FORCE" != "true" ]]; then
    http=$(curl -s -w '%{http_code}' -o "$tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -X POST "$KB_BASE/api/workflows?dryRun=true" \
      -d "$payload")
    if [[ "$http" -lt 200 || "$http" -ge 300 ]]; then
      echo "  FAILED preflight (HTTP $http):" >&2
      cat "$tmp" >&2
      rm -f "$tmp"
      exit 1
    fi
    existing_ids=$(jq -c '.existingIds // []' "$tmp")
    payload=$(jq --argjson existing "$existing_ids" \
      '.workflows |= map(select(.id as $id | $existing | index($id) | not))' \
      <<< "$payload")
    if [[ "$(jq '.workflows | length' <<< "$payload")" == "0" ]]; then
      echo "  All source-controlled workflow IDs already exist — skipping"
      rm -f "$tmp"
      return 0
    fi
  fi

  local overwrite=""
  [[ "$FORCE" == "true" ]] && overwrite="?overwrite=true"
  http=$(curl -s -w '%{http_code}' -o "$tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -X POST "$KB_BASE/api/workflows${overwrite}" \
    -d "$payload")

  if [[ "$http" -lt 200 || "$http" -ge 300 ]] || [[ "$(jq '.failed | length // 0' "$tmp" 2>/dev/null)" != "0" ]]; then
    echo "  FAILED bulk workflow deployment (HTTP $http):" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  echo "  OK (HTTP $http) — created $(jq '.created | length // 0' "$tmp") workflow(s)"
  rm -f "$tmp"
}

setup_workflows() {
  local dashboard_world_id dashboard_detail_id space_prefix=""
  dashboard_world_id=$(jq -r \
    'select(.type == "dashboard" and .attributes.title == "Aircraft World Overview") | .id' \
    elasticsearch/kibana/adsb-saved-objects.ndjson | head -1)
  dashboard_detail_id=$(jq -r \
    'select(.type == "dashboard" and .attributes.title == "Aircraft Detail") | .id' \
    elasticsearch/kibana/adsb-saved-objects.ndjson | head -1)
  [[ -n "${KB_SPACE:-}" ]] && space_prefix="/s/${KB_SPACE}"

  step_label "Configuring notification and news connectors"
  local slack_connector_id="${SLACK_CONNECTOR_ID:-d85ca362-fb82-56f6-867c-4ef2c356d912}"
  if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    local slack_payload slack_check_code
    slack_payload=$(jq -n --arg url "$SLACK_WEBHOOK_URL" \
      '{connector_type_id: ".slack", name: "ADS-B Daily Briefing", secrets: {webhookUrl: $url}}')
    slack_check_code=$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      "$KB_BASE/api/actions/connector/$slack_connector_id")
    if [[ "$slack_check_code" == "200" && "$FORCE" != "true" ]]; then
      echo "  Slack connector already exists — skipping"
    else
      local slack_method="POST"
      [[ "$slack_check_code" == "200" ]] && slack_method="PUT"
      warn_on_fail "Saving Slack connector" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -X "$slack_method" "$KB_BASE/api/actions/connector/$slack_connector_id" \
        -d "$(if [[ "$slack_method" == "PUT" ]]; then jq 'del(.connector_type_id)' <<< "$slack_payload"; else printf '%s' "$slack_payload"; fi)"
    fi
  else
    echo "  Slack skipped (SLACK_WEBHOOK_URL not set)"
  fi

  local gnews_connector_id=""
  if [[ -n "${GNEWS_API_KEY:-}" ]]; then
    gnews_connector_id="${GNEWS_CONNECTOR_ID:-6e45c45d-cb6d-5e4c-a9f4-3b09b9677500}"
    local gnews_tmp gnews_http gnews_payload_file gnews_update_file
    gnews_tmp=$(mktemp)
    gnews_payload_file=$(mktemp)
    gnews_update_file=$(mktemp)
    jq -n --arg key "$GNEWS_API_KEY" '{
      connector_type_id: ".http",
      name: "ADS-B GNews Search",
      config: {url: "https://gnews.io", headers: null, hasAuth: false},
      secrets: {secretQueryParams: {apikey: $key}}
    }' > "$gnews_payload_file"
    jq 'del(.connector_type_id)' "$gnews_payload_file" > "$gnews_update_file"
    gnews_http=$(curl -s -w '%{http_code}' -o "$gnews_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X POST "$KB_BASE/api/actions/connector/$gnews_connector_id" \
      -d "@$gnews_payload_file")
    if [[ "$gnews_http" == "409" ]] || grep -q "already exists" "$gnews_tmp"; then
      if [[ "$FORCE" == "true" ]]; then
        gnews_http=$(curl -s -w '%{http_code}' -o "$gnews_tmp" \
          -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
          -H "kbn-xsrf: true" \
          -H "Content-Type: application/json" \
          -X PUT "$KB_BASE/api/actions/connector/$gnews_connector_id" \
          -d "@$gnews_update_file")
      else
        gnews_http=200
      fi
    fi
    if [[ "$gnews_http" -lt 200 || "$gnews_http" -ge 300 ]]; then
      echo "  WARNING (HTTP $gnews_http): secure GNews connector unavailable; news search disabled." >&2
      cat "$gnews_tmp" >&2
      gnews_connector_id=""
    else
      echo "  GNews API key stored in encrypted connector secrets"
    fi
    rm -f "$gnews_tmp" "$gnews_payload_file" "$gnews_update_file"
  else
    echo "  GNews skipped (GNEWS_API_KEY not set)"
  fi

  local hijack_workflow_id="adsb-squawk-7500-hijack-investigation"
  local WORKFLOW_BULK_PAYLOAD='{"workflows":[]}'
  prepare_workflow \
    "adsb-squawk-7500-hijack-investigation" \
    "Squawk 7500 Hijack Investigation" \
    "elasticsearch/workflows/squawk-7500-hijack-investigation.yaml" \
    "$dashboard_world_id" "$dashboard_detail_id" "$space_prefix" "$gnews_connector_id"

  prepare_workflow "adsb-daily-flight-briefing" "Daily Flight Briefing" \
    "elasticsearch/workflows/daily-flight-briefing.yaml" \
    "$dashboard_world_id" "$dashboard_detail_id" "$space_prefix" "$gnews_connector_id"
  prepare_workflow "adsb-squawk-7500-enrich" "Squawk 7500 Enrich" \
    "elasticsearch/workflows/squawk-7500-enrich.yaml" \
    "$dashboard_world_id" "$dashboard_detail_id" "$space_prefix" "$gnews_connector_id"
  prepare_workflow "adsb-squawk-7500-create-case" "Squawk 7500 Create Case" \
    "elasticsearch/workflows/squawk-7500-create-case.yaml" \
    "$dashboard_world_id" "$dashboard_detail_id" "$space_prefix" "$gnews_connector_id"
  prepare_workflow "adsb-aggregate-stats" "ADS-B Aggregate Stats" \
    "elasticsearch/workflows/adsb-aggregate-stats.yaml" \
    "$dashboard_world_id" "$dashboard_detail_id" "$space_prefix" "$gnews_connector_id"
  prepare_workflow "adsb-aircraft-history" "ADS-B Aircraft History Report" \
    "elasticsearch/workflows/adsb-aircraft-history.yaml" \
    "$dashboard_world_id" "$dashboard_detail_id" "$space_prefix" "$gnews_connector_id"
  prepare_workflow "adsb-airport-activity" "ADS-B Airport Activity Report" \
    "elasticsearch/workflows/adsb-airport-activity.yaml" \
    "$dashboard_world_id" "$dashboard_detail_id" "$space_prefix" "$gnews_connector_id"
  prepare_workflow "adsb-hijack-cases-summary" "Hijack Cases Summary" \
    "elasticsearch/workflows/hijack-cases-summary.yaml" \
    "$dashboard_world_id" "$dashboard_detail_id" "$space_prefix" "$gnews_connector_id"
  prepare_workflow "adsb-defunct-callsign-detector" "Defunct Callsign Detector" \
    "elasticsearch/workflows/adsb-defunct-callsign-detector.yaml" \
    "$dashboard_world_id" "$dashboard_detail_id" "$space_prefix" "$gnews_connector_id"
  deploy_workflow_batch

  step_label "Creating squawk 7500 alerting rule"
  local hijack_rule_id="7500a1e7-cafe-4bee-b500-deadbeef7500"
  local esql_query rule_payload rule_tmp rule_http
  esql_query='FROM demos-aircraft-adsb | WHERE @timestamp >= NOW() - 5 minutes AND squawk == "7500" | SORT @timestamp DESC | DEDUP icao24 | KEEP @timestamp, icao24, callsign, squawk, origin_country, latitude, longitude, baro_altitude, velocity, true_track, vertical_rate, on_ground, geo_altitude | LIMIT 100'
  rule_payload=$(jq -n --arg esql "$esql_query" --arg wf_id "$hijack_workflow_id" --arg dash_id "$dashboard_detail_id" '{
    name: "Squawk 7500 — Hijack Detection",
    rule_type_id: ".es-query",
    consumer: "observability",
    enabled: true,
    schedule: {interval: "5m"},
    tags: ["adsb", "squawk-7500", "hijack"],
    params: {
      searchType: "esqlQuery", esqlQuery: {esql: $esql}, timeField: "@timestamp",
      threshold: [0], thresholdComparator: ">", timeWindowSize: 5,
      timeWindowUnit: "m", size: 100, groupBy: "row"
    },
    artifacts: {dashboards: [{id: $dash_id}]},
    actions: [{
      id: "system-connector-.workflows",
      params: {subActionParams: {workflowId: $wf_id, summaryMode: false}, subAction: "run"}
    }]
  }')
  rule_tmp=$(mktemp)
  rule_http=$(curl -s -w '%{http_code}' -o "$rule_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
    "$KB_BASE/api/alerting/rule/$hijack_rule_id")
  if [[ "$rule_http" == "200" ]]; then
    rule_http=$(curl -s -w '%{http_code}' -o "$rule_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X PUT "$KB_BASE/api/alerting/rule/$hijack_rule_id" -d "$rule_payload")
  else
    rule_http=$(curl -s -w '%{http_code}' -o "$rule_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X POST "$KB_BASE/api/alerting/rule/$hijack_rule_id" -d "$rule_payload")
  fi
  if [[ "$rule_http" -lt 200 || "$rule_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $rule_http): Could not deploy hijack alert rule." >&2
    cat "$rule_tmp" >&2
  else
    echo "  OK (HTTP $rule_http)"
  fi
  rm -f "$rule_tmp"

  step_label "Verifying hijack workflow alert action"
  local verify_body verify_code
  verify_body=$(curl_kb -X GET "$KB_BASE/api/alerting/rule/$hijack_rule_id" 2>/dev/null)
  verify_code=$(http_code_of "$verify_body")
  if [[ "$verify_code" == "200" ]] && parse_response "$verify_body" |
    jq -e --arg wf "$hijack_workflow_id" \
      '.actions[]? | select(.id == "system-connector-.workflows" and .params.subActionParams.workflowId == $wf)' \
      >/dev/null; then
    echo "  Verified — alert action targets $hijack_workflow_id"
  else
    echo "  WARNING: hijack alert action could not be verified." >&2
  fi

  step_label "Creating stale ingest alerting rule"
  local stale_rule_id="57a1e1a7-cafe-4bee-b500-deadbeef0015"
  local stale_esql stale_payload stale_http stale_tmp
  stale_esql='FROM demos-aircraft-adsb | STATS last_seen = MAX(@timestamp) BY ingest_quadrant | WHERE last_seen IS NULL OR last_seen < NOW() - 15 minutes | KEEP ingest_quadrant, last_seen'
  stale_payload=$(jq -n --arg esql "$stale_esql" '{
    name: "ADS-B — Stale Ingest",
    rule_type_id: ".es-query", consumer: "observability", enabled: true,
    schedule: {interval: "5m"}, tags: ["adsb", "ingest", "stale"],
    params: {
      searchType: "esqlQuery", esqlQuery: {esql: $esql}, timeField: "@timestamp",
      threshold: [0], thresholdComparator: ">", timeWindowSize: 20,
      timeWindowUnit: "m", size: 1, groupBy: "all"
    },
    actions: []
  }')
  stale_tmp=$(mktemp)
  stale_http=$(curl -s -o "$stale_tmp" -w '%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
    "$KB_BASE/api/alerting/rule/$stale_rule_id")
  if [[ "$stale_http" == "200" ]]; then
    [[ "$FORCE" == "true" ]] && stale_http=$(curl -s -o "$stale_tmp" -w '%{http_code}' \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X PUT "$KB_BASE/api/alerting/rule/$stale_rule_id" -d "$stale_payload")
  else
    stale_http=$(curl -s -o "$stale_tmp" -w '%{http_code}' \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X POST "$KB_BASE/api/alerting/rule/$stale_rule_id" -d "$stale_payload")
  fi
  if [[ "$stale_http" -ge 200 && "$stale_http" -lt 300 ]]; then
    echo "  OK (HTTP $stale_http)"
  else
    echo "  WARNING (HTTP $stale_http): Could not deploy stale-ingest rule." >&2
    cat "$stale_tmp" >&2
  fi
  rm -f "$stale_tmp"

  step_label "Creating enrichment-error alerting rule"
  local error_rule_id="57a1e1a7-cafe-4bee-b500-deadbeef0016"
  local error_esql error_payload error_http error_tmp
  error_esql='FROM demos-aircraft-adsb | WHERE @timestamp >= NOW() - 15 minutes | WHERE error.enrich.country IS NOT NULL OR error.enrich.airport IS NOT NULL | STATS failure_count = COUNT(*), latest_failure = MAX(@timestamp) | KEEP failure_count, latest_failure'
  error_payload=$(jq -n --arg esql "$error_esql" '{
    name: "ADS-B — Enrichment Errors",
    rule_type_id: ".es-query", consumer: "observability", enabled: true,
    schedule: {interval: "5m"}, tags: ["adsb", "ingest", "enrichment-error"],
    params: {
      searchType: "esqlQuery", esqlQuery: {esql: $esql}, timeField: "@timestamp",
      threshold: [0], thresholdComparator: ">", timeWindowSize: 15,
      timeWindowUnit: "m", size: 1, groupBy: "all"
    },
    actions: []
  }')
  error_tmp=$(mktemp)
  error_http=$(curl -s -o "$error_tmp" -w '%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
    "$KB_BASE/api/alerting/rule/$error_rule_id")
  if [[ "$error_http" == "200" ]]; then
    [[ "$FORCE" == "true" ]] && error_http=$(curl -s -o "$error_tmp" -w '%{http_code}' \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X PUT "$KB_BASE/api/alerting/rule/$error_rule_id" -d "$error_payload")
  else
    error_http=$(curl -s -o "$error_tmp" -w '%{http_code}' \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X POST "$KB_BASE/api/alerting/rule/$error_rule_id" -d "$error_payload")
  fi
  if [[ "$error_http" -ge 200 && "$error_http" -lt 300 ]]; then
    echo "  OK (HTTP $error_http)"
  else
    echo "  WARNING (HTTP $error_http): Could not deploy enrichment-error rule." >&2
    cat "$error_tmp" >&2
  fi
  rm -f "$error_tmp"

  step_label "Installing Agent Builder traces dashboard"
  local traces_tmp traces_http tracing_setting_http
  traces_tmp=$(mktemp)
  tracing_setting_http=$(curl -s -o "$traces_tmp" -w '%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -X POST "$KB_BASE/api/kibana/settings" \
    -d '{"changes":{"agentBuilder:tracing:enabled":true}}')
  if [[ "$tracing_setting_http" -lt 200 || "$tracing_setting_http" -ge 300 ]]; then
    echo "  Trace collection setting unchanged (HTTP $tracing_setting_http); 9.5 defaults it to enabled"
  fi
  traces_http=$(curl -s -o "$traces_tmp" -w '%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -X POST "$KB_BASE/internal/gen_ai_settings/agent_builder/tracing_dashboard" \
    -d '{"enabled":true}')
  if [[ "$traces_http" -ge 200 && "$traces_http" -lt 300 ]]; then
    echo "  Installed (HTTP $traces_http); trace collection is enabled by default in 9.5"
  elif [[ "$traces_http" == "404" ]]; then
    echo "  Skipped — traces dashboard requires Kibana 9.5+"
  else
    echo "  WARNING (HTTP $traces_http): Could not install traces dashboard." >&2
    cat "$traces_tmp" >&2
  fi
  rm -f "$traces_tmp"
}

register_wf_tool() {
  local tool_id="$1" wf_id="$2" tool_desc="$3" tags_json="$4"
  [[ -z "$wf_id" ]] && return 0

  step_label "Registering $tool_id workflow tool"

  local tool_payload
  tool_payload=$(jq -n --arg id "$tool_id" --arg desc "$tool_desc" \
    --argjson tags "$tags_json" --arg wf_id "$wf_id" \
    '{id: $id, description: $desc, type: "workflow", tags: $tags, configuration: {workflow_id: $wf_id}}')

  local tool_tmp tool_http
  tool_tmp=$(mktemp)
  tool_http=$(curl -s -w '%{http_code}' -o "$tool_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/agent_builder/tools" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -d "$tool_payload")

  if [[ "$tool_http" -ge 200 && "$tool_http" -lt 300 ]]; then
    echo "  Workflow tool registered (HTTP $tool_http)"
  elif [[ "$tool_http" == "409" ]] || { [[ "$tool_http" == "400" ]] && grep -q "already exists" "$tool_tmp"; }; then
    if [[ "$FORCE" == "true" ]]; then
      local tool_update_payload
      tool_update_payload=$(echo "$tool_payload" | jq 'del(.id, .type)')
      tool_http=$(curl -s -w '%{http_code}' -o "$tool_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/agent_builder/tools/$tool_id" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d "$tool_update_payload")
      if [[ "$tool_http" -ge 200 && "$tool_http" -lt 300 ]]; then
        echo "  Workflow tool updated (HTTP $tool_http)"
      else
        echo "  WARNING: Could not update workflow tool (HTTP $tool_http)" >&2
        cat "$tool_tmp" >&2
      fi
    else
      echo "  Workflow tool already registered — skipping"
    fi
  else
    echo "  WARNING: Could not register workflow tool (HTTP $tool_http)" >&2
    cat "$tool_tmp" >&2
  fi
  rm -f "$tool_tmp"
}

# ---------------------------------------------------------------------------
# register_wf_tool_from_file <tool_id> <workflow_id>
# Loads description and tags from elasticsearch/tools/<tool_id>.json and
# calls register_wf_tool with the source-controlled workflow ID.
# ---------------------------------------------------------------------------
register_wf_tool_from_file() {
  local tool_id="$1" wf_id="$2"
  local tool_json="elasticsearch/tools/${tool_id}.json"

  if [[ ! -f "$tool_json" ]]; then
    echo "  WARNING: Tool JSON not found: $tool_json — skipping" >&2
    return 0
  fi

  local tool_desc tags_json
  tool_desc=$(jq -r '.description' "$tool_json")
  tags_json=$(jq -c '.tags // []' "$tool_json")

  register_wf_tool "$tool_id" "$wf_id" "$tool_desc" "$tags_json"
}

# ---------------------------------------------------------------------------
# Group: tools
# ---------------------------------------------------------------------------

setup_tools() {
  step_label "Deploying workflow tools from elasticsearch/tools/"

  local tool_json tool_id wf_id_field tool_payload tool_tmp tool_http

  for tool_json in elasticsearch/tools/*.json; do
    [[ -f "$tool_json" ]] || continue
    tool_id=$(jq -r '.id' "$tool_json")
    step_label "  Deploying tool: $tool_id"

    # Resolve source-controlled workflow IDs from the placeholders committed
    # in each tool definition. Workflows deploy before tools.
    local placeholder stable_wf_id=""
    placeholder=$(jq -r '.configuration.workflow_id' "$tool_json")

    case "$placeholder" in
      __ADSB_AGGREGATE_STATS_WF_ID__)   stable_wf_id="adsb-aggregate-stats" ;;
      __ADSB_AIRCRAFT_HISTORY_WF_ID__)  stable_wf_id="adsb-aircraft-history" ;;
      __ADSB_AIRPORT_ACTIVITY_WF_ID__)  stable_wf_id="adsb-airport-activity" ;;
      __ADSB_DEFUNCT_CALLSIGN_DETECTOR_WF_ID__) stable_wf_id="adsb-defunct-callsign-detector" ;;
      __HIJACK_CASES_SUMMARY_WF_ID__)   stable_wf_id="adsb-hijack-cases-summary" ;;
      __SQUAWK_7500_ENRICH_WF_ID__)     stable_wf_id="adsb-squawk-7500-enrich" ;;
      __SQUAWK_7500_CREATE_CASE_WF_ID__) stable_wf_id="adsb-squawk-7500-create-case" ;;
    esac

    if [[ -z "$stable_wf_id" ]]; then
      echo "  WARNING: Unknown workflow placeholder '$placeholder' for tool $tool_id — skipping" >&2
      continue
    fi

    register_wf_tool_from_file "$tool_id" "$stable_wf_id"
  done
}

# ---------------------------------------------------------------------------
# Group: skills
# ---------------------------------------------------------------------------

setup_skills() {
  step_label "Deploying agent skills from elasticsearch/skills/"

  local skill_json skill_id skill_tmp skill_http

  for skill_json in elasticsearch/skills/*.json; do
    [[ -f "$skill_json" ]] || continue
    skill_id=$(jq -r '.id' "$skill_json")
    step_label "  Deploying skill: $skill_id"

    skill_tmp=$(mktemp)
    skill_http=$(curl -s -w '%{http_code}' -o "$skill_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/agent_builder/skills" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -d "@$skill_json")

    if [[ "$skill_http" -ge 200 && "$skill_http" -lt 300 ]]; then
      echo "  Skill deployed (HTTP $skill_http)"
    elif [[ "$skill_http" == "409" ]] || { [[ "$skill_http" == "400" ]] && grep -q "already exists" "$skill_tmp"; }; then
      if [[ "$FORCE" == "true" ]]; then
        local skill_update_payload
        skill_update_payload=$(jq 'del(.id)' "$skill_json")
        skill_http=$(curl -s -w '%{http_code}' -o "$skill_tmp" \
          -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
          -X PUT "$KB_BASE/api/agent_builder/skills/$skill_id" \
          -H "kbn-xsrf: true" \
          -H "Content-Type: application/json" \
          -d "$skill_update_payload")
        if [[ "$skill_http" -ge 200 && "$skill_http" -lt 300 ]]; then
          echo "  Skill updated (HTTP $skill_http)"
        else
          echo "  WARNING: Could not update skill $skill_id (HTTP $skill_http)" >&2
          cat "$skill_tmp" >&2
        fi
      else
        echo "  Skill already exists — skipping"
      fi
    else
      echo "  WARNING: Could not deploy skill $skill_id (HTTP $skill_http)" >&2
      cat "$skill_tmp" >&2
    fi
    rm -f "$skill_tmp"
  done
}

# ---------------------------------------------------------------------------
# Group: demouser
# ---------------------------------------------------------------------------

create_kibana_role() {
  local role_name="$1" role_payload="$2"

  if [[ "$FORCE" != "true" ]]; then
    local check_http
    check_http=$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: ApiKey $SETUP_API_KEY_ENCODED" \
      "$KB_BASE/api/security/role/$role_name")
    if [[ "$check_http" == "200" ]]; then
      echo "  Role '$role_name' already exists — skipping"
      return 0
    fi
  fi

  local role_tmp role_http
  role_tmp=$(mktemp)
  role_http=$(curl -s -w '%{http_code}' -o "$role_tmp" \
    -H "Authorization: ApiKey $SETUP_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -X PUT "$KB_BASE/api/security/role/$role_name" \
    -d "$role_payload")

  if [[ "$role_http" == "400" || "$role_http" == "404" ]]; then
    echo "  Skipped — roles API not available on this deployment (HTTP $role_http)"
    rm -f "$role_tmp"
    _KIBANA_ROLES_UNAVAILABLE=true
    return 0
  elif [[ "$role_http" == "403" ]]; then
    echo "  Skipped — API key lacks privileges to create roles (HTTP 403)"
    rm -f "$role_tmp"
    _KIBANA_ROLES_UNAVAILABLE=true
    return 0
  elif [[ "$role_http" -lt 200 || "$role_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $role_http): Could not create role '$role_name'." >&2
    cat "$role_tmp" >&2
    rm -f "$role_tmp"
    return 0
  fi
  rm -f "$role_tmp"

  if [[ "$FORCE" == "true" ]]; then
    echo "  Updated role '$role_name'"
  else
    echo "  Created role '$role_name'"
  fi
  return 0
}

create_demo_user() {
  local username="$1" full_name="$2" email="$3" role="$4" password="$5"

  if [[ "$FORCE" != "true" ]]; then
    local check_body
    check_body=$(curl -s \
      -H "Authorization: ApiKey $SETUP_API_KEY_ENCODED" \
      "$BASE/_security/user/$username")
    if echo "$check_body" | jq -e ".[\"$username\"]" &>/dev/null; then
      echo "  User '$username' already exists — skipping (password unchanged)"
      return 2
    fi
  fi

  local user_tmp user_http
  user_tmp=$(mktemp)
  user_http=$(curl -s -w '%{http_code}' -o "$user_tmp" \
    -H "Authorization: ApiKey $SETUP_API_KEY_ENCODED" \
    -X PUT "$BASE/_security/user/$username" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg pw "$password" \
      --arg role "$role" \
      --arg fn "$full_name" \
      --arg em "$email" \
      '{password: $pw, full_name: $fn, email: $em, roles: [$role]}')")

  if [[ "$user_http" -lt 200 || "$user_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $user_http): Could not create user '$username'." >&2
    cat "$user_tmp" >&2
    rm -f "$user_tmp"
    return 1
  fi
  rm -f "$user_tmp"

  if [[ "$FORCE" == "true" ]]; then
    echo "  Updated user '$username' with role '$role'"
  else
    echo "  Created user '$username' with role '$role'"
  fi
  return 0
}

setup_demouser() {
  step_label "Creating demo user roles and users"

  local space_scope
  if [[ -n "${KB_SPACE:-}" ]]; then
    space_scope="[\"${KB_SPACE}\"]"
  else
    space_scope="[\"*\"]"
  fi

  # --- Role: adsb-demo-users (audience-facing) ---
  local viewer_payload
  viewer_payload=$(jq -n --argjson spaces "$space_scope" '{
    description: "ADSB Demo Users",
    elasticsearch: {
      cluster: [],
      indices: [
        {
          names: [
            "demos-aircraft-adsb*",
            "logs-opensky.state_vector-*",
            "adsb*",
            "geo.shapes-world.countries-50m",
            "traces-agent_builder.otel-*"
          ],
          privileges: ["read", "view_index_metadata"]
        },
        {
          names: [".cases", ".cases-activity", ".cases-attachments"],
          privileges: ["read", "view_index_metadata"],
          allow_restricted_indices: true
        }
      ]
    },
    kibana: [
      {
        base: [],
        feature: {
          dashboard_v2: ["read"],
          discover_v2: ["read"],
          maps_v2: ["read"],
          visualize_v2: ["read"],
          observabilityCasesV3: ["read"],
          agentBuilder: ["read"],
          workflowsManagement: ["read", "workflow_execute"],
          actions: ["read"]
        },
        spaces: $spaces
      }
    ]
  }')

  _KIBANA_ROLES_UNAVAILABLE=false
  create_kibana_role "adsb-demo-users" "$viewer_payload"
  if [[ "$_KIBANA_ROLES_UNAVAILABLE" == "true" ]]; then
    echo "  Could not create demo roles — skipping demo user setup"
    return 0
  fi

  # --- Role: adsb-demo-power-users (behind-the-scenes presenter) ---
  local power_payload
  power_payload=$(jq -n --argjson spaces "$space_scope" '{
    description: "ADSB Demo Power Users",
    elasticsearch: {
      cluster: ["monitor"],
      indices: [
        {
          names: ["demos-aircraft-adsb*", "logs-opensky.state_vector-*", "adsb*", "geo.shapes-world.countries-50m"],
          privileges: ["read", "view_index_metadata", "monitor"]
        },
        {
          names: [".internal.alerts-*"],
          privileges: ["read", "view_index_metadata"],
          allow_restricted_indices: true
        },
        {
          names: [".cases", ".cases-activity", ".cases-attachments"],
          privileges: ["read", "view_index_metadata"],
          allow_restricted_indices: true
        }
      ]
    },
    kibana: [
      {
        base: [],
        feature: {
          dashboard_v2: ["read"],
          discover_v2: ["read"],
          maps_v2: ["read"],
          visualize_v2: ["read"],
          observabilityCasesV3: ["all"],
          agentBuilder: ["all"],
          workflowsManagement: ["read"],
          actions: ["all"],
          dev_tools: ["all"],
          indexPatterns: ["read"],
          savedObjectsManagement: ["read"],
          advancedSettings: ["read"],
          stackAlerts: ["all"]
        },
        spaces: $spaces
      }
    ]
  }')

  create_kibana_role "adsb-demo-power-users" "$power_payload"

  # --- User: goose (audience-facing) ---
  local goose_pass goose_rc
  goose_pass="$(openssl rand -base64 16)"
  create_demo_user "goose" "Goose" "goose@adsb-demo.local" "adsb-demo-users" "$goose_pass" && goose_rc=$? || goose_rc=$?
  if [[ "$goose_rc" -eq 0 ]]; then
    echo ""
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │  Demo user: goose                       │"
    echo "  │  Password:  $goose_pass  │"
    echo "  │  Role:      adsb-demo-users             │"
    echo "  └─────────────────────────────────────────┘"
    echo ""
  fi

  # --- User: maverick (behind-the-scenes presenter) ---
  local maverick_pass maverick_rc
  maverick_pass="$(openssl rand -base64 16)"
  create_demo_user "maverick" "Maverick" "maverick@adsb-demo.local" "adsb-demo-power-users" "$maverick_pass" && maverick_rc=$? || maverick_rc=$?
  if [[ "$maverick_rc" -eq 0 ]]; then
    echo ""
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │  Demo user: maverick                    │"
    echo "  │  Password:  $maverick_pass  │"
    echo "  │  Role:      adsb-demo-power-users       │"
    echo "  └─────────────────────────────────────────┘"
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Run selected groups
# ---------------------------------------------------------------------------

echo "ADS-B Demo Setup"
echo "Groups: $SELECTED_GROUPS"
[[ "$FORCE" == "true" ]] && echo "Mode: --force (overwriting existing resources)"
[[ -n "${KB_SPACE:-}" ]] && echo "Space: $KB_SPACE"
echo ""

[[ "$SKIP_SERVICE_USER" == "false" ]] && setup_serviceuser
group_enabled "ingestkey" && setup_ingestkey
group_enabled "space"     && setup_space
group_enabled "ilm"       && setup_ilm
group_enabled "indices"   && setup_indices
group_enabled "enrich"    && setup_enrich
group_enabled "pipelines" && setup_pipelines
group_enabled "kibana"    && setup_kibana
group_enabled "cases"     && setup_cases
group_enabled "workflows" && setup_workflows
group_enabled "tools"     && setup_tools
group_enabled "skills"    && setup_skills
group_enabled "agents"    && setup_agents
group_enabled "demouser"  && setup_demouser

echo ""
echo "Setup complete."
