#!/usr/bin/env python3
"""Validate the source-controlled ADS-B data-platform configuration."""

import json
from pathlib import Path


ROOT = Path(__file__).parents[1]
COVERAGE_NOTE = "generated airport coverage zone"
COUNTRY_FIELDS = {
    "ADM0_A3",
    "ADMIN",
    "BRK_A3",
    "CONTINENT",
    "ISO_A3",
    "NAME",
    "NAME_LONG",
    "REGION_UN",
    "REGION_WB",
    "SOVEREIGNT",
    "SUBREGION",
}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def validate_template() -> None:
    template = load_json(ROOT / "elasticsearch/indices/adsb-index-template.json")
    settings = template["template"]["settings"]["index"]
    mappings = template["template"]["mappings"]["properties"]
    lifecycle = template["template"]["lifecycle"]

    assert "lifecycle" not in settings
    assert lifecycle["enabled"] is True
    assert lifecycle["data_retention"] == "730d"
    assert COUNTRY_FIELDS <= mappings["geo"]["properties"].keys()
    assert mappings["ingest_quadrant"]["type"] == "keyword"
    assert mappings["airport"]["properties"]["match_type"]["type"] == "keyword"
    assert mappings["error"]["properties"]["enrich"]["properties"]


def validate_pipeline() -> None:
    pipeline = load_json(
        ROOT / "elasticsearch/pipelines/adsb-ingest-pipeline.json"
    )
    enrich_processors = [
        processor["enrich"]
        for processor in pipeline["processors"]
        if "enrich" in processor
    ]
    assert len(enrich_processors) == 2
    for processor in enrich_processors:
        assert "ignore_failure" not in processor
        assert {next(iter(item)) for item in processor["on_failure"]} == {
            "append",
            "set",
        }


def validate_logstash() -> None:
    expected_guard = (
        "if ([latitude] or [latitude] =~ /.*/) and "
        "([longitude] or [longitude] =~ /.*/) {"
    )
    for quadrant in range(1, 5):
        config = (ROOT / f"logstash/pipeline/adsb_q{quadrant}.conf").read_text()
        assert expected_guard in config


def validate_airports() -> None:
    lines = (
        ROOT / "data/adsb-airports-geo-data.ndjson"
    ).read_text().splitlines()
    assert len(lines) % 2 == 0
    assert len(lines) // 2 == 893

    document_ids = set()
    for offset in range(0, len(lines), 2):
        action = json.loads(lines[offset])["index"]
        source = json.loads(lines[offset + 1])
        assert action["_id"] == str(source["ne_id"])
        assert COVERAGE_NOTE in source["comments"]
        assert action["_id"] not in document_ids
        document_ids.add(action["_id"])


def validate_lifecycle_and_import() -> None:
    ilm = load_json(ROOT / "elasticsearch/indices/adsb-ilm-policy.json")
    assert "found-snapshots" not in json.dumps(ilm)
    assert "frozen" not in ilm["policy"]["phases"]

    settings = load_json(
        ROOT
        / "elasticsearch/indices/adsb-historical-import-cluster-settings.json"
    )
    persistent = settings["persistent"]
    assert persistent["data_stream.past_tsdb_index_creation_enabled"] is True
    assert persistent["data_streams.past_tsdb_index_interval"] == "2d"


def validate_agent_errors() -> None:
    config = (ROOT / "elastic-agent/elastic-agent.yml").read_text()
    assert '"error": {' in config
    assert '"ingest_quadrant": state.quadrant' in config
    assert '"GET /api/states/all: "' in config
    assert '"events": []' not in config


def validate_dashboard_as_code() -> None:
    dashboard = load_json(
        ROOT / "elasticsearch/kibana/adsb-operations-dashboard.json"
    )
    assert dashboard["title"] == "ADS-B Operations & Cases"
    assert {panel["type"] for panel in dashboard["pinned_panels"]} == {
        "esql_control",
        "time_slider_control",
    }
    assert len(dashboard["panels"]) == 5
    queries = [
        panel["config"]["data_source"]["query"]
        for panel in dashboard["panels"]
        if panel["type"] == "vis"
    ]
    assert any("error.enrich" in query for query in queries)
    assert any("space_id == \"__KB_SPACE_ID__\"" in query for query in queries)
    assert any("MV_EXPAND case.tags" in query for query in queries)
    assert any("?emergency_squawk" in query for query in queries)
    assert sum("?_tstart" in query and "?_tend" in query for query in queries) == 3


def validate_workflow_runtime_guards() -> None:
    workflows = ROOT / "elasticsearch/workflows"
    detector = (workflows / "adsb-defunct-callsign-detector.yaml").read_text()
    assert "inputs.lookback_hours | default: 24" in detector

    for name in ("daily-flight-briefing.yaml", "hijack-cases-summary.yaml"):
        assert 'from: "now-24h"' in (workflows / name).read_text()

    enrich = (workflows / "squawk-7500-enrich.yaml").read_text()
    investigation = (
        workflows / "squawk-7500-hijack-investigation.yaml"
    ).read_text()
    assert "name: has_callsign" not in enrich
    assert "name: has_callsign" not in investigation

    create_case = (workflows / "squawk-7500-create-case.yaml").read_text()
    assert 'case_action: "{{ variables.case_action }}"' in create_case
    assert 'case: "${{ variables.case }}"' in create_case


def main() -> None:
    for path in (ROOT / "elasticsearch/indices").glob("*.json"):
        load_json(path)
    validate_template()
    validate_pipeline()
    validate_logstash()
    validate_airports()
    validate_lifecycle_and_import()
    validate_agent_errors()
    validate_dashboard_as_code()
    validate_workflow_runtime_guards()
    print("Data-platform configuration is valid")


if __name__ == "__main__":
    main()
