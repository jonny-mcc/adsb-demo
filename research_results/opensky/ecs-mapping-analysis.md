# ECS mapping analysis — OpenSky Network

ECS reference used for this analysis: field names that exist in ECS 8.x/9.x as described by the `ecs-field-mappings` skill (pinned in Elastic packages at `git@v9.3.0` unless entity leaves force a newer pin). This package has **no entity streams**, so it does not need ECS 9.4+ `entity.attributes` leaves.

No source field is an IP address, user, or hash. `related.ip`, `related.user`, and `related.hash` have no contributors.

`geo` and `as` cannot sit at the document root. Coordinates in this API are already WGS84 degrees, not IP addresses, so a GeoIP database lookup does not apply.

Custom fields use the namespace `opensky.<data_stream>.<field>`.

## Stream classification

Research-time entity rule: an entity stream needs both “no event timestamp” and “idempotent re-read of a population”. None of these payloads qualify.

| Proposed stream | event.kind | Why |
|-----------------|------------|-----|
| `state_vector` | `event` | Each row is an observation at `time_position` or `last_contact`. Re-polling returns a new snapshot, not a directory of durable assets. |
| `flight` | `event` | Each row is a movement bounded by `firstSeen` and `lastSeen`. |
| `track` | `event` | Each waypoint has its own Unix `time`. The parent object’s `startTime` / `endTime` bound that track. |

`event.category` has no aviation value. The closest allowed value is `host` if the transponder is modelled as the host that emitted the report. If that reading is rejected during build, leave `event.category` unset rather than inventing a value. `event.outcome` is not set: these APIs do not report success or failure of an action. `event.action` has no source verb.

| Stream | event.kind | event.category | event.type | event.outcome |
|--------|------------|----------------|------------|---------------|
| `state_vector` | `event` | `[host]` | `[info]` | omit |
| `flight` | `event` | `[host]` | `[info]` | omit |
| `track` | `event` | `[host]` | `[info]` | omit |

Constants that apply to every stream:

| ECS field | Value |
|-----------|--------|
| `observer.vendor` | `OpenSky Network` |
| `observer.product` | `OpenSky REST API` |
| `event.module` | `opensky` |

`observer.type` is left unset. The documented examples (firewall, ids, proxy, and similar) do not include a surveillance feed.

## State vector

Primary timestamp is `time_position` when it is non-null, otherwise `last_contact`. Both are Unix seconds and need a seconds-to-date conversion. `last_contact` is the better `event.created` candidate when both exist, because it is “last message received” rather than “last position”. The envelope `time` is the snapshot clock (`[time - 1, time]`); keep it as a custom date, not as `@timestamp`, so a missing position does not get stamped with the poll time and look fresher than it is.

| Source | ECS or custom field | Notes |
|--------|---------------------|-------|
| `icao24` | `host.id` | Stable emitter id for the life of the transponder address. Also copy to `opensky.state_vector.icao24` only if a keyword that preserves hex formatting is required beyond `host.id`. Prefer a single destination: `host.id`. |
| `callsign` | `opensky.state_vector.callsign` | Space-padded, nullable, not a stable hostname. Do not map to `host.name` without trimming; even trimmed, the callsign changes between flights. |
| trimmed callsign, when non-null | `related.hosts` | Only after the padding spaces are removed. `icao24` is not a hostname and does not belong in `related.hosts`. |
| `origin_country` | `opensky.state_vector.origin_country` | Country inferred from the address allocation. It is **not** the country under the aircraft. Do not map to `host.geo.country_name` or `source.geo.country_name`. |
| `time_position` | `@timestamp` when non-null | Unix seconds. |
| `last_contact` | `@timestamp` when `time_position` is null; otherwise `event.created` | Unix seconds. |
| envelope `time` | `opensky.state_vector.response_time` | Unix seconds. Snapshot validity instant. |
| `latitude` + `longitude` | `host.geo.location` | `geo_point`. Only when both are non-null. Parent must be `host`, not root `geo`. |
| `latitude` | `opensky.state_vector.latitude` | `double`. Kept beside the geo_point because some consumers filter on the raw numbers. |
| `longitude` | `opensky.state_vector.longitude` | `double`. |
| `baro_altitude` | `opensky.state_vector.baro_altitude` | `double`, metres. No ECS altitude field matches barometric altitude. |
| `geo_altitude` | `opensky.state_vector.geo_altitude` | `double`, metres. |
| `on_ground` | `opensky.state_vector.on_ground` | `boolean`. |
| `velocity` | `opensky.state_vector.velocity` | `double`, metres per second. Not `host.network.egress.bytes`. |
| `true_track` | `opensky.state_vector.true_track` | `double`, degrees clockwise from north. |
| `vertical_rate` | `opensky.state_vector.vertical_rate` | `double`, metres per second. Positive means climb. |
| `sensors` | `opensky.state_vector.sensors` | `long` array. Usually null on `/states/all`. |
| `squawk` | `opensky.state_vector.squawk` | `keyword`. Values such as `7500`, `7600`, `7700` are conventions on this keyword, not ECS `event.kind: alert`. |
| `spi` | `opensky.state_vector.spi` | `boolean`. |
| `position_source` | `opensky.state_vector.position_source` | `long`. Enum 0 ADS-B, 1 ASTERIX, 2 MLAT (not currently returned by REST), 3 FLARM. |
| `category` | `opensky.state_vector.category` | `long`, 0–20. Absent unless `extended=1`. Enum labels are in `references/field-schema-analysis.md`. A separate name field would be derived and is not a source field. |

The ADS-B demo’s `location`, `geo.NAME`, `geo.SUBREGION`, `airport.*`, and `airport.activity` are **not** source fields. They are computed after ingest from a country polygon set and an airport catalogue. An official package that only decodes the API will not contain them. Dashboards in that demo that aggregate `airport.iata_code` or `geo.SUBREGION` depend on those extra datasets.

`icao24` is a low-cardinality dimension in the demo’s time-series index. A `logs-*` data stream does not require that setting. Record it as a modelling note, not as an ECS field.

## Flight

One schema for `/flights/all`, `/flights/aircraft`, `/flights/arrival`, and `/flights/departure`. Which URL was called is deployment context. A custom keyword for that mode is justified only as a copy of the user’s selected endpoint, not as a field the API returns. Suggested name if the build records it: `opensky.flight.scope` with values `all`, `aircraft`, `arrival`, `departure`.

| Source | ECS or custom field | Notes |
|--------|---------------------|-------|
| `firstSeen` | `event.start` and `@timestamp` | Unix seconds. `@timestamp` follows the start of the flight so a late-arriving historical row stays on the day it departed. |
| `lastSeen` | `event.end` | Unix seconds. |
| `icao24` | `host.id` | Lower case hex. |
| `callsign` | `opensky.flight.callsign` | Nullable, often space-padded. Same `related.hosts` note as state vectors. |
| `estDepartureAirport` | `opensky.flight.est_departure_airport` | `keyword`, ICAO code, not IATA. No coordinates are provided, so there is no `source.geo.location`. |
| `estArrivalAirport` | `opensky.flight.est_arrival_airport` | `keyword`, ICAO code. |
| `estDepartureAirportHorizDistance` | `opensky.flight.est_departure_airport_horiz_distance` | `long`, metres. |
| `estDepartureAirportVertDistance` | `opensky.flight.est_departure_airport_vert_distance` | `long`, metres. |
| `estArrivalAirportHorizDistance` | `opensky.flight.est_arrival_airport_horiz_distance` | `long`, metres. |
| `estArrivalAirportVertDistance` | `opensky.flight.est_arrival_airport_vert_distance` | `long`, metres. |
| `departureAirportCandidatesCount` | `opensky.flight.departure_airport_candidates_count` | `long`. |
| `arrivalAirportCandidatesCount` | `opensky.flight.arrival_airport_candidates_count` | `long`. |

No `related.ip`. Airport codes are not hosts.

## Track

The natural document grain is one waypoint. The parent `icao24`, `startTime`, `endTime`, and `calllsign` repeat on every waypoint so a waypoint can be queried alone. The wire key is `calllsign`.

| Source | ECS or custom field | Notes |
|--------|---------------------|-------|
| waypoint `time` | `@timestamp` | Unix seconds. |
| `startTime` | `event.start` | Unix seconds. Same value on every waypoint of the track. |
| `endTime` | `event.end` | Unix seconds. |
| `icao24` | `host.id` | |
| `calllsign` | `opensky.track.callsign` | Read the misspelt wire key. Store the corrected custom name. |
| waypoint latitude + longitude | `host.geo.location` | `geo_point` when both are non-null. |
| waypoint `latitude` | `opensky.track.latitude` | `double`. |
| waypoint `longitude` | `opensky.track.longitude` | `double`. |
| waypoint `baro_altitude` | `opensky.track.baro_altitude` | `double`, metres. |
| waypoint `true_track` | `opensky.track.true_track` | `double`, degrees. |
| waypoint `on_ground` | `opensky.track.on_ground` | `boolean`. |

`path` as a nested array on a single document is a worse fit: ECS `@timestamp` would have to collapse many waypoint times onto one event.

## Related and geo summary

| ECS field | Source |
|-----------|--------|
| `related.hosts` | Trimmed callsign (`callsign` or wire `calllsign`) when non-null |
| `related.ip` | none |
| `related.user` | none |
| `related.hash` | none |
| `host.geo.location` | State-vector latitude/longitude; track waypoint latitude/longitude |
| GeoIP / ASN | Not applicable. No IP fields. |

## Entity field coverage

N/A. No stream is an entity stream (`event.kind: asset`).
