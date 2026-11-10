#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

bash -n setup.sh

while IFS= read -r -d '' file; do
  jq -e . "$file" >/dev/null
done < <(find elasticsearch/agents elasticsearch/tools elasticsearch/cases \
  -type f -name '*.json' -print0)

if grep -q 's|__GNEWS_API_KEY__|' setup.sh; then
  echo "setup.sh must not substitute the GNews API key into workflow YAML." >&2
  exit 1
fi

grep -q 'secretQueryParams' setup.sh
grep -q 'adsb-squawk-7500-hijack-investigation' setup.sh
grep -q '/api/workflows?dryRun=true' setup.sh
grep -q 'deploy_workflow_batch' setup.sh
grep -q 'Verifying hijack workflow alert action' setup.sh
grep -q 'ADS-B — Stale Ingest' setup.sh
grep -q 'ADS-B — Enrichment Errors' setup.sh

ruby -e '
  require "yaml"
  Dir["elasticsearch/workflows/*.yaml", ".github/workflows/*.yml"].each do |path|
    YAML.safe_load(File.read(path), aliases: true)
  end
'

if [[ -f tests/validate_data_platform.py ]]; then
  python3 tests/validate_data_platform.py
fi

echo "Static validation passed."
