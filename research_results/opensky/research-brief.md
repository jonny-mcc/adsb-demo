# Research Brief: OpenSky Network

> **Generated:** 2026-10-28
> **Researcher:** AI-assisted research via /research-integration skill
> **Status:** READY FOR REVIEW
> **Confidence:** HIGH for `/states/all` and the OAuth2 client-credentials flow (official REST page plus the official Python client, and a working poll in the ADS-B demo). MEDIUM for `/flights/*` and `/tracks/all` field lists that the REST HTML page no longer prints in full (the official Python client is the field source). LOW for the departure-interval sentence that contradicts both its own example and the Python client.

## 1. Product Overview

### 1.1 What is it?

The OpenSky Network is a community receiver network that collects air-traffic surveillance (ADS-B and related broadcasts) and exposes it for research and operational awareness. The public REST API returns live and recent aircraft state vectors, estimated flight intervals, and experimental trajectories. Consumers are researchers, aviation authorities, and operators who want network-wide positions without running their own receiver. A local dump1090/tar1090 receiver is a different data source and is not this API.

### 1.2 Vendor

- **Vendor name:** OpenSky Network
- **Product name:** OpenSky Network REST API
- **Product category:** Aviation surveillance / ADS-B data service
- **Vendor documentation portal:** https://openskynetwork.github.io/opensky-api/rest.html
- **Data access overview:** https://opensky-network.org/data/
- **Terms of use:** https://opensky-network.org/about/terms-of-use

### 1.3 Data generated

The REST API generates three payload families:

- **State vectors** — one positional snapshot per aircraft (identity, callsign, position, altitudes, speed, track, squawk, emitter category).
- **Flights** — estimated departure/arrival intervals with ICAO airport codes and distances. Not a second-by-second track.
- **Tracks** — a simplified waypoint path for one aircraft (experimental).

It does not generate security alerts, audit logs, or receiver health metrics. Routes, ADS-C, and MLAT state vectors are explicitly **not** on this REST API. OpenSky says those exist in Trino tables (`readsb_adsc_sv`, `readsb_mlat_sv`) for approved research users. REST state vectors therefore do not currently include `position_source` 2 (MLAT).

### 1.4 Existing Elastic coverage

There is no `opensky` package in `elastic/integrations`. A repository search for OpenSky returned unrelated packet-capture integrations (`network_traffic`), not this API.

Prior art is a private demo, not a Fleet package:

- `face0b1101/adsb-demo` (upstream) and `jonny-mcc/adsb-demo` (fork). Through tag `v1.11.5` the two `main` branches share the same Elasticsearch, Kibana, Logstash, and workflow design. The fork’s branch `cursor/elastic-agent-opensky-ingest` adds a standalone Elastic Agent CEL policy.
- Both only call `GET /states/all`, four times, with hemisphere boxes, OAuth2 client credentials, and **without** `extended=1`. They do not call `/states/own`, `/flights/*`, or `/tracks/all`.
- Logstash (`logstash/pipeline/adsb_q1.conf` and the three sibling files) uses a 360-second heartbeat because `http_poller` cannot perform the token exchange. The Agent policy (`elastic-agent/elastic-agent.yml`) uses native `auth.oauth2` and decodes vector indexes 0–16.
- Documents are written to the demo data stream `demos-aircraft-adsb`. An ingest pipeline then geo-matches a Natural Earth country polygon and an airport catalogue. Those enriched fields (`geo.NAME`, `airport.iata_code`, `airport.activity`, and similar) are **not** in the OpenSky JSON. Workflows and dashboards in the demo query those enriched names.

This research targets a normal Elastic package on `logs-opensky.*`, not the demo index names.

### 1.5 Market coverage

None of IBM QRadar, Splunk, or Sumo Logic publishes an integration that collects the OpenSky REST API. Splunk has a near-miss that polls a local dump1090/tar1090 receiver (AirSpace Watch TA) and a radar visualisation that does not collect data. Other “OpenSky” hits are different companies.

| Platform | Integration name | Supported data sources | Collection method | Link |
|----------|------------------|------------------------|-------------------|------|
| IBM QRadar | No integration found | N/A | N/A | N/A |
| Splunk | No OpenSky Network integration | N/A | N/A | N/A |
| Sumo Logic | No integration found | N/A | N/A | N/A |

See `references/market-coverage.md` for the near-miss listings, name collisions, and search notes.

## 2. Data Collection Method

### 2.1 Recommended method

- **Input type:** `cel`
- **Rationale:** Every supported export is an HTTPS GET that returns JSON. The collection input is `cel`. The API needs an OAuth2 client-credentials token on a different host from the data host, which the CEL `auth.oauth2` block supports. There is no syslog feed, no log file, and no S3 or Event Hub delivery of this REST data.

### 2.2 Alternative methods

| Method | Input type | Pros | Cons |
|--------|------------|------|------|
| OpenSky REST (recommended) | `cel` | Documented, OAuth2 client credentials, covers states, flights, and tracks | Credit buckets, large state payloads, flights are windowed and partly nightly, tracks are per aircraft and experimental |
| OpenSky Trino / historical warehouse | none (SQL warehouse, not an Elastic input) | Full history, including ADS-C and MLAT tables | Not a REST poll. Access is limited to universities, governments, aviation authorities, or a commercial licence. Out of scope for a package. |
| Local dump1090 / tar1090 receiver | `cel` or `filestream` against the receiver’s own JSON | No OpenSky credits; one antenna you control | Not the OpenSky Network. Different schema (`hex`, feet, knots). Already approximated by Splunk’s AirSpace Watch TA. |
| Logstash heartbeat plus two HTTP filters | not an integration input | Works around Logstash’s lack of OAuth2 on `http_poller` | Legacy demo only. Do not copy into a Fleet package. |

### 2.3 Vendor-side setup required

1. Create an OpenSky Network account and open the account page.
2. Create an API client. Record `client_id` and `client_secret`. The Python client alternatively reads a file `{"clientId": "...", "clientSecret": "..."}`.
3. No scope list is published. The official token request does not send a `scope` parameter.
4. Accept the OpenSky terms of use. Higher credit tiers exist for active feeders (receiver uptime) and licensed users. The Trino warehouse has a separate access policy; it is not required for REST.
5. `/states/own` only returns data if that account owns receivers. Otherwise the API responds `403`.

Anonymous calls work for a reduced `/states/all` only. They are not a target configuration: `time` is ignored, the daily credit cap is 400, and flights and tracks in the official examples are authenticated.

## 3. Data Source Details

### 3.1 Connection and authentication

- Base URL: `https://opensky-network.org/api`
- API version: documentation set 1.4.0. The path is unversioned.
- Authentication: OAuth2 client credentials (see below)
- Rate limits: credit buckets, not a fixed “requests per minute” header. Details below and in `references/api-spec-notes.md`.
- Documentation: https://openskynetwork.github.io/opensky-api/rest.html

**OAuth2**

- Method: OAuth2
- Grant type: `client_credentials` only. No authorization-code grant and no refresh-token grant are documented.
- Authorization URL: none
- Token URL: `https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token`
- Refresh URL: none. On HTTP 401, request a new access token with the same client credentials.
- Scopes required: none documented. The official curl body is `grant_type`, `client_id`, and `client_secret` only.
- All available scopes: not published
- Client registration: OpenSky account page → create API client → `client_id` and `client_secret`
- Token lifetime: 30 minutes (`expires_in` defaults to 1800 seconds in the official client if the field is missing). The Python client refreshes 30 seconds early.
- Refresh token lifetime: not applicable
- Token response format: `access_token` and `expires_in` are read by the official client. `token_type` is not read. `[UNVERIFIED]` whether a `refresh_token` is ever returned; the published flow does not use one.
- Access token usage: `Authorization: Bearer <access_token>`
- Additional notes: token host and API host differ. Basic authentication with a username and password is no longer accepted.

**Credits**

Three independent buckets: `/states/*`, `/flights/*`, `/tracks/*`. `/states/own` costs nothing.

| Tier | Credits per bucket | Refill |
|------|--------------------|--------|
| Anonymous | 400 | Daily |
| Standard user | 4,000 | Daily |
| Active feeder (≥30% uptime/month) | 8,000 | Daily |
| Licensed user | 14,400 | Hourly |

`/states/all` cost by bounding-box area (latitude span × longitude span):

| Area | Credits |
|------|---------|
| ≤ 25 sq° or an ICAO24-only query | 1 |
| 25–100 sq° | 2 |
| 100–400 sq° | 3 |
| > 400 sq° or no box (global) | 4 |

A 90° × 180° quadrant is 16,200 sq° and costs 4 credits, the same as one global call. Four quadrants cost 16 credits per cycle. At a 6-minute interval that is 3,840 state credits per day (inside the standard 4,000 cap, far above the anonymous 400 cap). One global call every 6 minutes is 960 credits per day.

`/flights/*` and `/tracks/*` cost by UTC day-partitions crossed: 4 credits when the range is live or under 24 hours; then 30, 60×N, 120×N, 240×N, 480×N, or 960×N as the partition count grows. The full table is in `references/api-spec-notes.md`.

Headers: `X-Rate-Limit-Remaining` while credits remain. HTTP 429 includes `X-Rate-Limit-Retry-After-Seconds`. No other rate-limit header is documented. The 429 body schema is not documented.

Authenticated `/states/all`: `time` older than one hour returns `400`. Resolution is 5 seconds. Anonymous callers ignore `time` and use a 10-second resolution.

### 3.2 Endpoints / data paths

| Endpoint | Method | Purpose | Event types |
|----------|--------|---------|-------------|
| `/states/all` | GET | State vectors for the network, an optional ICAO24 list, and/or a WGS84 box. Optional `time`, `extended=1`. | State vector |
| `/states/own` | GET | Same payload for the caller’s receivers. Optional `time`, `icao24`, repeatable `serials`, `extended`. Auth required. | State vector |
| `/flights/all` | GET | Flights in `[begin, end]`. Window ≤ 2 hours. | Flight |
| `/flights/aircraft` | GET | Flights for one lower-case `icao24` in `[begin, end]`. Window ≤ 2 days. Previous UTC day or earlier only. | Flight |
| `/flights/arrival` | GET | Arrivals at one ICAO `airport` in `[begin, end]`. Nightly batch. | Flight |
| `/flights/departure` | GET | Departures from one ICAO `airport` in `[begin, end]`. | Flight |
| `/tracks/all` | GET | One aircraft trajectory. Required `icao24` and `time` (`0` = live). Experimental. | Track waypoints |

The REST heading for tracks says `GET /tracks`. The curl example and the Python client call `GET /tracks/all`. Use `/tracks/all`.

### 3.3 Pagination (API only)

- **Mechanism:** none
- **Page size parameter:** none
- **Next page indicator:** none
- **Termination condition:** the HTTP response is the full result. For every `/flights/*` call, HTTP **404 with an empty body** means “no flights in this interval”, not a broken URL. The official client turns that 404 into an empty list.
- **Documentation:** https://openskynetwork.github.io/opensky-api/rest.html

State responses put every aircraft in one `states` array. A global response is large (the ADS-B demo allows a 50 MiB body and a 90-second timeout). Track responses put every waypoint in one `path` array. There is no bulk tracks endpoint.

### 3.4 Time-based filtering (API only)

- **Start time parameter:** flights use required `begin`. States and tracks do not have a start parameter.
- **End time parameter:** flights use required `end`.
- **Point time parameter:** states use optional `time`. Tracks use required `time` (`0` for live).
- **Time format:** Unix epoch seconds. Not milliseconds. Not ISO-8601.
- **Timezone:** UTC epoch. Airport windows in the Python client are counted in UTC calendar dates.
- **Sort order:** not documented for flights. Track waypoints follow the published selection rules (time order along the path). State vectors are one snapshot, not a sorted log.
- **Incremental collection:** there is no cursor. The next poll either asks for “now” (omit state `time`, or track `time=0`) or moves the flight `[begin, end]` window. Authenticated state history stops at one hour. Flight windows must stay inside the per-endpoint maximum (2 hours, 2 days, or the arrival/departure limit in the open questions). Overlapping flight windows can return the same flight again. No flight id is documented beyond the combination of `icao24` and `firstSeen`.
- **Backfill:** states, one hour; flights, inside the window caps and, for aircraft and arrivals, only through the previous day; tracks, 30 days.

### 3.5 Reference documentation

| Title | URL | Relevance |
|-------|-----|-----------|
| OpenSky REST API 1.4.0 | https://openskynetwork.github.io/opensky-api/rest.html | Endpoints, OAuth2, credits, vector layout, track rules |
| Official Python client | https://github.com/openskynetwork/opensky-api/blob/master/python/opensky_api.py | Flight field list, interval checks, 404 handling, token refresh, `/tracks/all` |
| Python API narrative | https://openskynetwork.github.io/opensky-api/python.html | Points at the same client |
| OpenSky data access | https://opensky-network.org/data/ | Trino versus REST |
| Terms of use | https://opensky-network.org/about/terms-of-use | Usage conditions |

Local copies and notes: `temp/opensky_api.py`, `references/api-spec-notes.md`, `references/field-schema-analysis.md`.

## 4. Data Format and Structure

### 4.1 Format overview

- **Wire format:** JSON
- **Encoding:** UTF-8 (JSON text; `[UNVERIFIED]` only in the sense that the docs do not print a charset parameter)
- **Compression:** none documented
- **Envelope:**
  - States: `{"time": <int>, "states": [ [ ... ], ... ] }`
  - Flights: a bare JSON array of objects. Empty interval: HTTP 404, empty body.
  - Tracks: one object `{"icao24", "startTime", "endTime", "calllsign", "path": [ [ ... ] ] }`

State vectors and waypoints are positional arrays. Flight rows are named objects in camelCase. The track callsign key is the misspelling `calllsign`.

### 4.2 Event types

| Event type | Description | Relative volume | Priority |
|------------|-------------|-----------------|----------|
| State vector | One aircraft in one `/states/*` snapshot | High (thousands of aircraft per global poll) | High |
| Flight | One estimated flight from any `/flights/*` URL | Medium, and only as fresh as the nightly batch on aircraft/arrival endpoints | High |
| Track waypoint | One point inside `path` for one aircraft | Low per request, but one HTTP call per aircraft | Medium (experimental API) |

There is no subtype field inside a flight object. Arrival versus departure is which URL was called.

### 4.3 Field inventory

Full tables, nullability, and the `position_source` and `category` enumerations are in `references/field-schema-analysis.md`. Summary:

**State vector indexes:** `0 icao24`, `1 callsign`, `2 origin_country`, `3 time_position`, `4 last_contact`, `5 longitude`, `6 latitude`, `7 baro_altitude`, `8 on_ground`, `9 velocity`, `10 true_track`, `11 vertical_rate`, `12 sensors`, `13 geo_altitude`, `14 squawk`, `15 spi`, `16 position_source`, `17 category` (only if `extended=1`).

**Flight object:** `icao24`, `firstSeen`, `estDepartureAirport`, `lastSeen`, `estArrivalAirport`, `callsign`, `estDepartureAirportHorizDistance`, `estDepartureAirportVertDistance`, `estArrivalAirportHorizDistance`, `estArrivalAirportVertDistance`, `departureAirportCandidatesCount`, `arrivalAirportCandidatesCount`.

**Track object:** `icao24`, `startTime`, `endTime`, `calllsign`, `path[]` where each point is `time`, `latitude`, `longitude`, `baro_altitude`, `true_track`, `on_ground`.

Callsigns are up to 8 characters and are often space-padded. `origin_country` is the country implied by the ICAO address, not the country under the aircraft. Altitudes and speeds are metres and metres per second.

### 4.4 Sample data

See `references/sample-events/`. Every file is a **[CONSTRUCTED EXAMPLE]** that follows the documented schema and reuses ICAO addresses and timestamps from the official examples. They are not live captures.

- `state_vector.json` — `/states/all` envelope with `extended` on the first row and a 17-element row with nulls
- `flight.json` — one `/flights/all` object, one arrival object, and the 404 empty-body case
- `track.json` — `/tracks/all` object using the wire key `calllsign`, plus one decoded waypoint

See `references/field-schema-analysis.md` for the complete inventory. See `temp/opensky_api.py` for the raw client.

#### Inline sample (state vector, constructed)

```json
{
  "time": 1458564121,
  "states": [
    ["3c6444", "DLH123  ", "Germany", 1458564120, 1458564121, 8.55, 47.45, 11582.4, false, 230.1, 85.4, -1.2, null, 11612.0, "1000", false, 0, 6]
  ]
}
```

### 4.5 Timestamp handling

- **Primary timestamp field:** state `time_position` (else `last_contact`); flight `firstSeen`; track waypoint `time`
- **Format:** Unix epoch seconds
- **Timezone:** UTC
- **Additional timestamps:** state envelope `time` (snapshot clock), state `last_contact`, flight `lastSeen`, track `startTime` and `endTime`

### 4.6 Special parsing considerations

- Positional arrays, not objects, for states and waypoints. A vector without `extended` has 17 elements (indexes 0–16). With `extended=1` it has 18 (index 17 = category). The official client ignores unexpected extra trailing elements.
- JSON `null` is inside the array. It is not an omitted key. The ADS-B demo’s Logstash config treats a leftover sprintf placeholder as null after a failed copy; a JSON decoder sees real nulls instead.
- Flight HTTP 404 with an empty body is an empty result.
- `calllsign` on tracks is spelled with three `l`s on the wire.
- `GET /tracks` in the heading versus `GET /tracks/all` in the example and client.
- Departure interval text says the window “must cover more than two days” while the example is one hour and the Python client allows at most one UTC midnight crossing. See open questions.
- MLAT (`position_source` 2) is documented as an enum value and stated to be absent from REST.
- Country polygon, nearest airport, and airport activity in the ADS-B demo are not in this payload.

## 5. ECS Mapping Analysis

### 5.1 Categorization per event type

| Event type | event.kind | event.category | event.type | event.outcome |
|------------|------------|----------------|------------|---------------|
| State vector | `event` | `[host]` | `[info]` | omit |
| Flight | `event` | `[host]` | `[info]` | omit |
| Track waypoint | `event` | `[host]` | `[info]` | omit |

`host` is the closest allowed category if the transponder is the host that emitted the report. There is no aviation category. Do not invent one. Omit `event.outcome`. Squawk `7500` / `7600` / `7700` stay on a keyword; they are not `event.kind: alert` by themselves.

`observer.vendor` = `OpenSky Network`. `observer.product` = `OpenSky REST API`. `event.module` = `opensky`.

### 5.2 Field mappings

Detail and types are in `ecs-mapping-analysis.md`. Custom names:

| Source field | ECS field or custom field | Notes |
|--------------|---------------------------|-------|
| `icao24` | `host.id` | Stable transponder address |
| `time_position` | `@timestamp` | Unix seconds. If null, use `last_contact`. |
| `last_contact` | `event.created` when `time_position` is present, else `@timestamp` | Unix seconds |
| `latitude`, `longitude` | `host.geo.location` | `geo_point` only when both are non-null. Not root `geo`. |
| `callsign` / wire `calllsign` | `opensky.<stream>.callsign` | Trim only as a documented transform note. Padded source is not `host.name`. |
| trimmed callsign | `related.hosts` | When non-null. Do not put `icao24` here. |
| `origin_country` | `opensky.state_vector.origin_country` | Not `host.geo.country_name` (that would claim the aircraft is geographically there). |
| `firstSeen` | `event.start` and flight `@timestamp` | Unix seconds |
| `lastSeen` | `event.end` | Unix seconds |
| `estDepartureAirport`, `estArrivalAirport` | `opensky.flight.est_departure_airport`, `opensky.flight.est_arrival_airport` | ICAO codes. No coordinates on the flight object. |
| Flight distance and candidate-count fields | `opensky.flight.*` snake_case names in `ecs-mapping-analysis.md` | Integers, metres for distances |
| Track `startTime`, `endTime` | `event.start`, `event.end` | Repeated on each waypoint document |
| `baro_altitude`, `geo_altitude`, `velocity`, `true_track`, `vertical_rate`, `on_ground`, `squawk`, `spi`, `sensors`, `position_source`, `category` | `opensky.<stream>.*` | No ECS field matches these surveillance measurements |

### 5.3 Related field enrichment

| ECS enrichment field | Source fields |
|----------------------|---------------|
| `related.ip` | none |
| `related.user` | none |
| `related.hosts` | trimmed callsign, or trimmed wire `calllsign` |
| `related.hash` | none |

### 5.4 Geo enrichment candidates

No IP addresses. Do not run GeoIP. `host.geo.location` is populated from the API’s own latitude and longitude (state vector and track waypoint). Flight rows have airport codes only.

The demo’s country-polygon and airport-proximity joins need external datasets (Natural Earth, an airport catalogue). They are not part of this API and are not source fields for the package.

### 5.5 Entity field coverage

N/A — no entity data streams identified. Every proposed stream has an event timestamp and is a new observation or interval, not an idempotent inventory.

## 6. Configuration Plan

Variables match `configuration-plan.md` and the CEL/OAuth2 tables in the research skill. No `preserve_original_event` (not valid for CEL) and no pagination size.

### 6.1 Required configuration variables

| Variable | Type | Title | Description | Default | Show user |
|----------|------|-------|-------------|---------|-----------|
| `url` | url | API URL | REST root, scheme included | `https://opensky-network.org/api` | yes |
| `client_id` | text | OAuth2 client ID | From the OpenSky API client | none | yes |
| `client_secret` | password | OAuth2 client secret | From the OpenSky API client | none | yes |
| `token_url` | url | OAuth2 token URL | Client-credentials endpoint | `https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token` | yes |
| `interval` | text | Poll interval | Credit cost depends on box area and endpoint | `6m` / `1h` / `10m` by stream (see configuration plan) | yes |
| `flight_scope` | text | Flight endpoint | `all`, `aircraft`, `arrival`, or `departure` | `all` | yes, flight stream |
| `icao24` | text | ICAO24 address | Required for track and for flight scope `aircraft`. Optional filter on states. | none | yes when required |
| `airport` | text | Airport ICAO code | Required for flight scopes `arrival` and `departure` | none | yes when required |

### 6.2 Optional configuration variables

| Variable | Type | Title | Description | Default | Show user |
|----------|------|-------|-------------|---------|-----------|
| `initial_interval` | text | Initial lookback | Capped by the endpoint (1 hour states, 2 hours `flights/all`, 2 days aircraft, 30 days tracks) | `0s` or `2h` or `24h` by stream | yes |
| `lamin`, `lamax`, `lomin`, `lomax` | text | Bounding box | All four or none. Area sets state credit cost. | none | yes, state stream |
| `extended` | bool | Include aircraft category | Sends `extended=1` (vector index 17) | `true` | yes, state stream |
| `own_sensors_only` | bool | Own receivers only | Calls `/states/own`. Zero credits. 403 if the account has no receivers. | `false` | yes, state stream |
| `serials` | text | Receiver serials | Repeatable filter on `/states/own` | none | yes, state stream |
| `scopes` | text | OAuth2 scopes | Unpublished; official example sends none | empty | no |
| `http_client_timeout` | text | HTTP timeout | Global state bodies are slow | `90s` | no |
| `proxy_url` | url | Proxy URL | Token host and API host | none | no |
| `ssl` | yaml | TLS settings | Standard CEL TLS block | none | no |
| `tags` | text | Tags | User tags | none | yes |
| `processors` | yaml | Processors | Standard processor block | none | no |

### 6.3 Deployment notes

Outbound HTTPS to `opensky-network.org` and `auth.opensky-network.org`. Several bounding boxes means several state-stream instances, each billed in credits. Do not assume four hemisphere quadrants are cheaper than one global call; each of those quadrants costs 4 credits. Global JSON bodies need a large response buffer (the demo uses 50 MiB); that is an agent limit, not a user credential. Track collection is one HTTP request per ICAO24 per interval. Flight scopes other than `all` are nightly data, not a live feed.

## 7. Recommended Integration Architecture

### 7.1 Package name

`opensky`

### 7.2 Data streams

| Data stream name | Input type | Stream kind | Source | Description |
|------------------|------------|-------------|--------|-------------|
| `state_vector` | `cel` | event | `GET /states/all` or `GET /states/own` | One document per aircraft per snapshot |
| `flight` | `cel` | event | `GET /flights/all`, `/flights/aircraft`, `/flights/arrival`, or `/flights/departure` | One document per flight object. `flight_scope` selects the URL. Schema does not change. |
| `track` | `cel` | event | `GET /tracks/all` | One document per waypoint, with track `startTime`, `endTime`, and callsign copied onto the waypoint |

Resulting data streams use the package dataset names, for example `logs-opensky.state_vector-<namespace>`. They are not `demos-aircraft-adsb`.

### 7.3 Architecture rationale

States and own-receiver states share one array layout, so they are one stream selected by `own_sensors_only`. The four flight URLs share one object schema, so they are one stream selected by `flight_scope` rather than four copies of the same fields. Tracks are a third stream because the payload is a single object plus a waypoint array, the endpoint is experimental, and it requires an ICAO24. Waypoint-per-document follows the data: each point has its own timestamp, while one document for the whole `path` would have to pick a single `@timestamp`.

### 7.4 Estimated complexity

- **Pipeline complexity:** moderate. Two positional decoders (state vector of length 17 or 18, waypoint of length 6) plus a flat flight object. Enums are small. No multiline text.
- **CEL complexity:** moderate. OAuth2 client credentials, three URL shapes, 404 meaning empty on flights, no pagination, large state bodies, and a per-aircraft track loop when more than one ICAO24 is configured.
- **Field count estimate:** about 20 source fields on `state_vector`, 12 on `flight`, 10 on `track`, plus the ECS fields in section 5.

## 8. Open Questions and Gaps

| # | Question | Impact | Suggested resolution |
|---|----------|--------|----------------------|
| 1 | Departure docs say the interval “must cover more than two days (UTC)” but the example is one hour and the Python client allows at most one UTC midnight. | Medium | Run `test-api.py` against a one-hour departure window and a two-day window. Prefer the behaviour that returns HTTP 200. |
| 2 | Is HTTP 404 with an empty body also what `/tracks/all` returns when `time=0` and the aircraft is not airborne? | Medium | The test script records status and body. The REST page does not say. |
| 3 | Does `/flights/all` include flights still in the air during the last two hours, or only completed flights? The nightly-batch note is written on `/flights/aircraft` and arrivals, not on `/flights/all`. | Medium | Compare a window ending now with a window ending yesterday. |
| 4 | Does `extended=1` change the credit cost? The cost table does not mention it. | Low | Compare `X-Rate-Limit-Remaining` with and without the parameter. |
| 5 | 400/401/403/429 body schema is unpublished. | Low | Keep the next real error body from `trace.json`. |
| 6 | REST commercial terms versus the Trino licence. The credit table has a “Licensed user” tier; the data page restricts Trino, not clearly the REST API. | Medium | Read https://opensky-network.org/about/terms-of-use before publishing the package, and do not claim a commercial grant this brief has not quoted. |
| 7 | Live confirmation of the wire key `calllsign`. It is in the HTML table and the Python class, but no live body was captured in this research. | Medium | `test-api.py` writes the track body to `trace.json` when `OPENSKY_ICAO24` is set. |

## 9. Source Attribution

| Source | URL | Access method | Date |
|--------|-----|---------------|------|
| OpenSky REST API 1.4.0 | https://openskynetwork.github.io/opensky-api/rest.html | Web fetch | 2026-10-28 |
| opensky-api Python client | https://github.com/openskynetwork/opensky-api/blob/master/python/opensky_api.py | Download to `temp/opensky_api.py` | 2026-10-28 |
| OpenSky data page | https://opensky-network.org/data/ | Web search snippet | 2026-10-28 |
| ADS-B demo (Logstash, Agent CEL, index template, ingest pipeline, workflows) | https://github.com/face0b1101/adsb-demo and https://github.com/jonny-mcc/adsb-demo | Local checkout of the fork plus README comparison | 2026-10-28 |
| Splunkbase AirSpace Watch TA | https://splunkbase.splunk.com/app/9301 | Web search | 2026-10-28 |
| Splunkbase Airspace Radar | https://splunkbase.splunk.com/app/8813 | Web search | 2026-10-28 |
| Sumo Logic QRadar automation (rejected name collision) | https://www.sumologic.com/help/docs/integrations/automation-integrations/ibm-qradar/ | Web search | 2026-10-28 |
| elastic/integrations search | https://github.com/elastic/integrations | Web search, no OpenSky package | 2026-10-28 |
