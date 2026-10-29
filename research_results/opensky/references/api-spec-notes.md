# OpenSky Network REST API — specification notes

> Sources: [OpenSky REST API 1.4.0](https://openskynetwork.github.io/opensky-api/rest.html) (fetched 2026-10-28) and the official client [`opensky_api.py`](https://github.com/openskynetwork/opensky-api/blob/master/python/opensky_api.py) saved at `temp/opensky_api.py`. Where those two disagree, both statements are recorded.

## Base URL and version

- REST root: `https://opensky-network.org/api`
- Documentation title: OpenSky REST API 1.4.0
- Versioning: no version segment in the path, no version header, no version query parameter
- Token endpoint (separate host): `https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token`
- Content type of successful data responses: `application/json`
- Token request content type: `application/x-www-form-urlencoded`

Routes, ADS-C, and MLAT data are not available through the REST API. The state-vector documentation states that REST state vectors do not contain MLAT positions (`position_source` 2). Those feeds exist in the OpenSky Trino tables `readsb_adsc_sv` and `readsb_mlat_sv`, which are outside this REST contract.

## Authentication

OpenSky documents a single automated flow: OAuth2 **client credentials**. Username/password basic authentication is no longer accepted.

| Item | Value |
|------|--------|
| Grant type | `client_credentials` only. No `authorization_code` flow, no refresh-token grant, and no personal-access-token page are documented. |
| Token URL | `https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token` |
| Authorization URL | None (no browser grant) |
| Request body | `grant_type=client_credentials`, `client_id`, `client_secret` |
| Scopes | None are sent in the official curl example or `TokenManager`. No scope list is published for this client. |
| Client registration | Log in at the OpenSky account page and create an API client. The UI returns `client_id` and `client_secret`. The Python client also reads a JSON file with keys `clientId` and `clientSecret`. |
| Documented token response fields | `access_token`, `expires_in` (default used by the client if missing: `1800`) |
| Token lifetime | 30 minutes. The client refreshes 30 seconds before `expires_in`. |
| Refresh token | Not documented for this grant. A `401 Unauthorized` means the access token has expired; the client must request a new one. |
| How the access token is sent | `Authorization: Bearer <access_token>` |
| Anonymous access | Allowed on `/states/all` only, with stricter limits (see below). `/states/own` without credentials returns `403`. Flight and track calls in the official examples are authenticated. |

`401` is the documented signal to discard the current access token and repeat the client-credentials POST.

## Credit quotas and rate limiting

All endpoints consume credits except `/states/own`. Credits are three independent buckets: `/states/*`, `/tracks/*`, and `/flights/*`. Spending one bucket does not reduce the others.

Per-bucket quota:

| Tier | Credits | Refill |
|------|---------|--------|
| Anonymous | 400 | Daily |
| Standard user | 4,000 | Daily |
| Active feeder (≥30% uptime/month) | 8,000 | Daily |
| Licensed user | 14,400 | Hourly |

Active-feeder status is recalculated every 2 hours. A tier upgrade takes effect after about 50 requests. The docs say a remaining balance above 4,000 at the start of a day confirms the 8,000-credit feeder allowance.

`/states/all` credit cost from bounding-box area (latitude span × longitude span, square degrees):

| Area | Credits |
|------|---------|
| ≤ 25 sq° or an ICAO24-only query | 1 |
| 25–100 sq° | 2 |
| 100–400 sq° | 3 |
| > 400 sq° or a global query (no box) | 4 |

A hemisphere quadrant (90° × 180° = 16,200 sq°) is in the global band and costs **4 credits**, the same as one unbounded `/states/all` call. Four such quadrants therefore cost **16 credits per cycle**, not 4.

`/flights/*` and `/tracks/*` cost by how many UTC calendar-day partitions the requested time range crosses:

| Partitions | Credits |
|------------|---------|
| Live / under 24 h | 4 |
| 1–2 | 30 |
| 3–10 | 60 × N |
| 11–15 | 120 × N |
| 16–20 | 240 × N |
| 21–25 | 480 × N |
| > 25 | 960 × N |

Response headers named by the documentation:

- `X-Rate-Limit-Remaining` — remaining balance while credits are available
- `X-Rate-Limit-Retry-After-Seconds` — present with HTTP `429 Too Many Requests` when the bucket is empty

No `Retry-After`, `X-RateLimit-Limit`, or reset-epoch header is documented. The 429 body format is not documented.

The official Python client also applies its own minimum gap between calls (`get_states`: 10 s anonymous / 5 s authenticated; `get_my_states`: 1 s). That gap is client behaviour, not an HTTP header from the server.

### What a standing poll costs

Factual arithmetic from the table above, for authenticated `/states/all`:

| Pattern | Credits per cycle | Cycles per day at 6 min | Credits per day |
|---------|-------------------|-------------------------|-----------------|
| One global call | 4 | 240 | 960 |
| Four hemisphere quadrants | 16 | 240 | 3,840 |
| One box ≤ 25 sq° | 1 | 240 | 240 |

3,840 is inside the standard 4,000 daily bucket and outside the anonymous 400 daily bucket. A global poll every 6 minutes (960/day) also exceeds the anonymous bucket. Anonymous `states/all` stays inside 400/day at one global call every 15 minutes (96 × 4 = 384) or one small box every 6 minutes (240).

`/states/own` adds no credits. It only returns aircraft seen by receivers registered to that account, and it requires authentication.

## State-vector time limits

| Caller | `time` parameter | Resolution |
|--------|------------------|------------|
| Anonymous | Ignored. Only the latest vectors are returned. | 10 seconds: `now - (now mod 10)` |
| Authenticated | Unix seconds. `t < now - 3600` returns `400 Bad Request`. | 5 seconds: `t - (t mod 5)` |

Omitted `time` means “current”. `/states/own` has no credit cost and no documented one-hour cap; the REST page says own-receiver vectors have no credit cost or time restriction.

## Endpoints

### `GET /states/all`

Purpose: current or recent state vectors for the whole network, an ICAO24 set, and/or a WGS84 box.

Query parameters (all optional):

| Name | Type | Notes |
|------|------|-------|
| `time` | integer | Unix seconds. See time limits above. |
| `icao24` | string | Lower-case hex. Repeat the parameter for more than one address. |
| `lamin`, `lomin`, `lamax`, `lomax` | float | Decimal degrees. All four are required together. Latitude −90..90, longitude −180..180 (enforced by the Python client). |
| `extended` | integer | `1` adds aircraft category as the 18th vector element. The Python client always sends `extended=true`. |

Response envelope:

```json
{ "time": 1458564121, "states": [ [ "...17 or 18 elements..." ] ] }
```

`time` is the instant the vectors are associated with. Each vector is the vehicle state over `[time - 1, time]`. `states` is null or absent when nothing was received; the Python client treats that as an empty list.

Vector elements are positional, not named. Index 0–16 are always documented. Index 17 (`category`) is documented only when `extended=1`. A vector without `extended` in the second sample row of `sample-events/state_vector.json` stops at index 16. Nulls are JSON `null` inside the array, not omitted keys. The Python client zips the array onto a fixed key list and ignores any further trailing elements.

Errors: `400` when authenticated `time` is older than one hour; `401` when the bearer token is expired; `429` when the states bucket is empty.

Example from the docs: `https://opensky-network.org/api/states/all?time=1458564121&icao24=3c6444`

Switzerland box from the docs: `lamin=45.8389&lomin=5.9962&lamax=47.8229&lomax=10.5226`.

### `GET /states/own`

Purpose: state vectors seen by the caller’s own receivers. Authentication is required (`403` otherwise). Credit cost is zero.

Query parameters (all optional):

| Name | Type | Notes |
|------|------|-------|
| `time` | integer | Unix seconds. Current time if omitted. |
| `icao24` | string | Repeatable hex address filter. |
| `serials` | integer | Repeatable receiver serial. Returns aircraft visible to at least one listed receiver. |
| `extended` | integer | Same category column as `/states/all`. The Python client sends it. |

Response shape matches `/states/all`.

### `GET /flights/all`

Purpose: flights that fall in `[begin, end]`.

| Name | Type | Required | Notes |
|------|------|----------|-------|
| `begin` | integer | yes | Unix seconds |
| `end` | integer | yes | Unix seconds |

The interval must be greater than zero and **must not be larger than two hours** (7,200 seconds). The Python client rejects `end - begin > 7200`.

Response: a JSON array of flight objects (see field inventory). If no flights exist in the interval, the service returns **HTTP 404 with an empty body**, not `200` and `[]`. The Python client maps that 404 to an empty list.

There is no page size, cursor, or `Link` header.

### `GET /flights/aircraft`

Purpose: flights for one aircraft whose departure and arrival both fall in `[begin, end]`.

| Name | Type | Required | Notes |
|------|------|----------|-------|
| `icao24` | string | yes | Lower-case hex |
| `begin` | integer | yes | Unix seconds |
| `end` | integer | yes | Unix seconds |

The interval must not be larger than **two days** (172,800 seconds). The Python client enforces that.

Flights are produced by a nightly batch. Only flights from the previous UTC day or earlier are available. Same 404-empty behaviour as `/flights/all`. Same flight object schema.

### `GET /flights/arrival`

Purpose: flights that arrived at one airport in `[begin, end]`.

| Name | Type | Required | Notes |
|------|------|----------|-------|
| `airport` | string | yes | ICAO identifier. The departure section says this is usually upper case. |
| `begin` | integer | yes | Unix seconds |
| `end` | integer | yes | Unix seconds |

REST prose says the interval must not be larger than two days. The Python client is stricter: `_count_utc_dates(begin, end)` must be `<= 1` (the window may cross at most one UTC midnight). Arrivals are nightly-batched, same as aircraft flights. 404 means no rows. Same flight object schema.

Example from the docs: `airport=EDDF&begin=1517227200&end=1517230800`.

### `GET /flights/departure`

Same parameters and the same flight object schema as arrival.

The REST page says: “The given time interval must cover more than two days (UTC)!” The worked example immediately below that sentence is a **one-hour** window (`1517227200` to `1517230800`). The Python client rejects any window spanning more than one UTC calendar-day boundary and does not require a minimum length beyond `begin < end`. Treat the “more than two days” sentence as a documentation error unless a live call proves otherwise. This is recorded as an open question in the research brief.

Nightly-batch wording is attached to the arrival section (“similar to flights”) and is not repeated verbatim on the departure section. The Python client does not special-case departure freshness.

### `GET /tracks/all`

The REST heading says operation `GET /tracks`. The only curl example and the Python client both call **`GET /tracks/all`**. Use `/tracks/all`.

| Name | Type | Required | Notes |
|------|------|----------|-------|
| `icao24` | string | yes | Lower-case hex |
| `time` | integer | yes | Any Unix time inside a known flight. `0` requests the live track if a flight is ongoing. |

The endpoint is described as experimental and may be out of order. History cannot be older than 30 days (`time != 0` and `now - time > 2592000` is rejected by the Python client).

Response is one JSON object, not an array:

| Property | Type | Notes |
|----------|------|-------|
| `icao24` | string | Lower-case hex |
| `startTime` | integer | Unix seconds of the first waypoint |
| `endTime` | integer | Unix seconds of the last waypoint |
| `calllsign` | string | **Three `l` characters.** Documented spelling, including in `FlightTrack`. 8 characters, nullable. |
| `path` | array | Waypoints as positional arrays |

Waypoint index: `0` time (Unix seconds), `1` latitude, `2` longitude, `3` baro_altitude (metres), `4` true_track (degrees clockwise from north), `5` on_ground (boolean). Latitude, longitude, barometric altitude, and true track can be null.

Waypoint selection rules published by OpenSky (not a page size): first point after expected departure or first position in range; last point before expected arrival or loss of coverage; at least one point every 15 minutes airborne; extra points when track changes by more than 2.5°, altitude changes by more than 100 m, or the on-ground flag changes.

There is no bulk “all aircraft tracks” operation. One request returns one aircraft.

## Pagination

None of the seven operations is paginated. Termination is “the body contained the full result”, or HTTP 404 with an empty body for the four `/flights/*` operations. States and tracks do not use 404 for an empty result in the documentation (`states` may be null; a missing live track is not given a dedicated status code beyond the experimental warning).

## Time filtering and incremental collection

| Family | Time parameters | Format | Sort | How far back |
|--------|-----------------|--------|------|--------------|
| `/states/all` | optional `time` | Unix seconds | One snapshot, not a time-sorted log | Authenticated: 1 hour. Anonymous: now only. |
| `/states/own` | optional `time` | Unix seconds | One snapshot | No REST time cap documented |
| `/flights/all` | required `begin`, `end` | Unix seconds, inclusive interval as documented (`[begin, end]`) | Not documented | Window ≤ 2 hours. No “since cursor”. |
| `/flights/aircraft` | required `begin`, `end` | Unix seconds | Not documented | Window ≤ 2 days, and only through the previous UTC day |
| `/flights/arrival`, `/flights/departure` | required `begin`, `end` | Unix seconds | Not documented | See the one-day versus two-day conflict above. Nightly batch for arrivals. |
| `/tracks/all` | required `time` | Unix seconds, or `0` for live | Waypoints are in path order | 30 days |

There is no opaque cursor and no `updated_since` parameter. A later poll sees a new snapshot (states, live track) or must move `begin`/`end` (flights). Flight rows are not given a separate document id. The stable aircraft key on every family is `icao24`. A flight row is distinguished by `icao24` plus `firstSeen` (and the estimated airports) but OpenSky does not document that pair as a primary key. State vectors can repeat the same `icao24` in one response only if the filters somehow overlap; a single box or global call returns one vector per aircraft in that snapshot.

Overlapping flight windows can return the same flight twice. The API does not describe a deduplication token.

## Error catalogue

| Status | When it is documented |
|--------|------------------------|
| 400 | Authenticated `/states/all` with `time` older than one hour. The Python client also rejects malformed boxes and illegal intervals locally, before the HTTP call. |
| 401 | Bearer token expired or rejected. |
| 403 | `/states/own` without authentication. |
| 404 | `/flights/*` when the interval has no flights. Empty body. Not a transport failure. |
| 429 | Credit bucket exhausted. `X-Rate-Limit-Retry-After-Seconds` says how long to wait. |

The JSON shape of 400/401/403/429 bodies is not documented. Calls are idempotent GETs (plus the token POST, which mints a new token each time).

## Prior art in the ADS-B demo

`face0b1101/adsb-demo` and its fork `jonny-mcc/adsb-demo` poll **only** `GET /states/all`, four times, with hemisphere boxes and no `extended` parameter. They do not call `/states/own`, `/flights/*`, or `/tracks/all`. Field names produced by that demo match indexes 0–16 of the state vector. Index 17 is absent unless `extended=1` is added.

Country polygons, nearest airport, and `airport.activity` in that demo are Elasticsearch enrichments. They are not fields in the OpenSky response.
