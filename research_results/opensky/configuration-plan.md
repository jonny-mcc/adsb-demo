# Configuration plan — `opensky`

Variables are the CEL and OAuth2 set from `data-collection-methods.md`, plus OpenSky query parameters that the REST API actually defines. `preserve_original_event` is not a CEL variable and is not listed. There is no page size: none of the endpoints is paginated, so `batch_size` / `page_size` is omitted.

Package name: `opensky`.

Shared OAuth2 values (`client_id`, `client_secret`, `token_url`) are the same for every data stream. `url` is the API root, not the token host.

## 6.1 Required configuration variables

| Variable | Type | Title | Description | Default | Show user | Streams |
|----------|------|-------|-------------|---------|-----------|---------|
| `url` | url | API URL | OpenSky REST root, including scheme. Paths such as `/states/all` are appended by the package. | `https://opensky-network.org/api` | yes | all |
| `client_id` | text | OAuth2 client ID | Client id from the OpenSky account page (API client). | none | yes | all |
| `client_secret` | password | OAuth2 client secret | Client secret from the same API client. | none | yes | all |
| `token_url` | url | OAuth2 token URL | Keycloak client-credentials token endpoint. | `https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token` | yes | all |
| `interval` | text | Poll interval | How often to poll. Credit cost depends on the stream and the bounding box. A global `/states/all` call costs 4 state-bucket credits; four hemisphere quadrants cost 16. | `6m` for `state_vector`; `1h` for `flight`; `10m` for `track` | yes | all |

`authorization_url` is not used. The only documented grant is `client_credentials`.

`flight` also requires a scope selector, because the four flight URLs take different required parameters:

| Variable | Type | Title | Description | Default | Show user | Streams |
|----------|------|-------|-------------|---------|-----------|---------|
| `flight_scope` | text | Flight endpoint | Which flight resource to call: `all`, `aircraft`, `arrival`, or `departure`. Response schema is the same. | `all` | yes | `flight` |
| `icao24` | text | ICAO24 address | Lower-case hex transponder address. Required when `flight_scope` is `aircraft`, and required for `track`. Optional repeatable filter on `state_vector`. | none | yes | `flight` (`aircraft`), `track`; optional elsewhere |
| `airport` | text | Airport ICAO code | ICAO airport identifier, usually upper case. Required when `flight_scope` is `arrival` or `departure`. | none | yes | `flight` |

## 6.2 Optional configuration variables

| Variable | Type | Title | Description | Default | Show user | Streams |
|----------|------|-------|-------------|---------|-----------|---------|
| `initial_interval` | text | Initial lookback | How far back the first poll reaches. `/states/all` rejects authenticated times older than 1 hour (`400`). `/flights/all` rejects a window longer than 2 hours. `/flights/aircraft` rejects a window longer than 2 days and only returns flights from the previous UTC day or earlier. `/tracks/all` rejects times older than 30 days; `0` means live. | `0s` for `state_vector` (current snapshot); `2h` for `flight` scope `all`; `24h` for other flight scopes; `0s` for `track` (live) | yes | all |
| `lamin` | text | Minimum latitude | WGS84 degrees, −90 to 90. Ignored unless all four box edges are set. Box area sets the `/states/all` credit cost. | none | yes | `state_vector` |
| `lamax` | text | Maximum latitude | WGS84 degrees, −90 to 90. | none | yes | `state_vector` |
| `lomin` | text | Minimum longitude | WGS84 degrees, −180 to 180. | none | yes | `state_vector` |
| `lomax` | text | Maximum longitude | WGS84 degrees, −180 to 180. | none | yes | `state_vector` |
| `extended` | bool | Include aircraft category | When true, send `extended=1` so state vectors include category index 17 (0–20). | `true` | yes | `state_vector` |
| `own_sensors_only` | bool | Own receivers only | When true, call `/states/own` instead of `/states/all`. Requires the OAuth client to belong to an account that owns receivers. Credit cost is zero. Other callers receive HTTP 403. | `false` | yes | `state_vector` |
| `serials` | text | Receiver serials | Repeatable receiver serials for `/states/own`. Aircraft seen by any listed receiver are returned. | none | yes | `state_vector` |
| `scopes` | text | OAuth2 scopes | OpenSky’s published client-credentials example sends no scope. Leave empty unless OpenSky documents one. | empty | no | all |
| `http_client_timeout` | text | HTTP timeout | Socket timeout. Global `/states/all` bodies are large; the ADS-B demo uses 90 seconds. | `90s` | no | all |
| `proxy_url` | url | Proxy URL | HTTP proxy for both the token host and the API host. | none | no | all |
| `ssl` | yaml | TLS settings | Standard CEL TLS block. | none | no | all |
| `tags` | text | Tags | User tags copied onto events. | none | yes | all |
| `processors` | yaml | Processors | Standard agent processor block. | none | no | all |

`own_sensors_only`, `serials`, the four box edges, `extended`, `flight_scope`, `icao24`, and `airport` are vendor request parameters, not pipeline switches.

## 6.3 Deployment notes

- One Fleet policy can hold one instance of each stream. Extra geographic boxes are extra instances of `state_vector` (each box is a separate poll and a separate credit charge). A hemisphere quadrant costs the same 4 credits as a global call, so four quadrants cost 16 credits per cycle.
- Standard accounts refill 4,000 state credits per day. Four quadrant polls every 6 minutes cost 3,840 of those credits. One global poll every 6 minutes costs 960. Anonymous access is not a supported configuration for this package because flights and tracks need a client, and anonymous state history is disabled.
- Flight and track credits are a different bucket from state credits. A live or sub-24-hour flight or track request costs 4 credits in that bucket. Wider historical ranges cost much more (see `references/api-spec-notes.md`).
- `/flights/aircraft`, `/flights/arrival`, and the arrival documentation’s nightly batch mean those scopes do not show “today”. Polling them every few minutes does not produce new same-day rows.
- `/tracks/all` is one aircraft per request and is marked experimental by OpenSky. A list of addresses means one request per address per interval.
- Token URL and API URL are different hosts (`auth.opensky-network.org` and `opensky-network.org`). Both need outbound HTTPS (443).
- The OpenSky terms of use apply. The historical Trino warehouse is a separate, access-controlled service and is not configured here.
- Global state responses need a large HTTP body allowance. The standalone demo policy sets `resource.max_body_size` to 50 MiB. That limit is an agent runtime setting; it is called out here so the build does not assume the CEL default buffer is enough. It is not a user-facing vendor credential.
