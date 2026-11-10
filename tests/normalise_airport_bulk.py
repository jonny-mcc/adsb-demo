#!/usr/bin/env python3
"""Normalise airport bulk actions and coverage-zone comments."""

import json
from pathlib import Path


DATA_FILE = Path(__file__).parents[1] / "data" / "adsb-airports-geo-data.ndjson"
COVERAGE_NOTE = (
    "geo.airspace is a generated airport coverage zone, not regulated airspace "
    "or a nearest-airport calculation."
)


def main() -> None:
    lines = DATA_FILE.read_text().splitlines()
    if len(lines) % 2:
        raise ValueError("Airport bulk data must contain action/source pairs")

    output = []
    for offset in range(0, len(lines), 2):
        action = json.loads(lines[offset])
        source = json.loads(lines[offset + 1])
        document_id = source.get("ne_id")
        if document_id is None:
            raise ValueError(f"Airport source line {offset + 2} has no ne_id")

        action["index"]["_id"] = str(document_id)
        comments = source.get("comments")
        if not comments:
            source["comments"] = COVERAGE_NOTE
        elif COVERAGE_NOTE not in comments:
            source["comments"] = f"{comments}; {COVERAGE_NOTE}"

        output.extend((json.dumps(action), json.dumps(source, ensure_ascii=False)))

    DATA_FILE.write_text("\n".join(output) + "\n")


if __name__ == "__main__":
    main()
