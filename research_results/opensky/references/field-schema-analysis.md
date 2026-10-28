# OpenSky field inventory

Extracted from the REST API 1.4.0 page and `temp/opensky_api.py` (`StateVector.keys`, `FlightData.keys`, `FlightTrack`, `Waypoint.keys`). Types below are the types in those sources.

Null means JSON `null`. The API does not omit null slots inside state-vector or waypoint arrays. Object fields on flights are documented as nullable where the description says “can be null”.

## State vector

Envelope of `GET /states/all` and `GET /states/own`:

| Field | Type | Always present | Description |
|-------|------|----------------|-------------|
| `time` | integer | yes, on HTTP 200 | Unix seconds. Every vector in `states` represents `[time - 1, time]`. |
| `states` | array of arrays, or null | key present; value may be null | One inner array per aircraft. |

Inner array. Indexes 0–16 are the base vector. Index 17 is present when the request set `extended=1`. The Python client will ignore indexes beyond 17.

| Index | Name | Type | Nullable | Description |
|------:|------|------|----------|-------------|
| 0 | `icao24` | string | no in practice (rows without an address are not useful; the demo drops empty addresses) | ICAO 24-bit transponder address, hex. Flight endpoints require lower case. State examples in the docs are lower case (`3c6444`). |
| 1 | `callsign` | string | yes | Up to 8 characters. Often space-padded. Null if none received. |
| 2 | `origin_country` | string | yes | Country **name** inferred from the ICAO address allocation, not the country under the current position. |
| 3 | `time_position` | integer | yes | Unix seconds of the last position. Null if OpenSky has had no position for this aircraft in the past 15 seconds. |
| 4 | `last_contact` | integer | documented as the field updated on every valid message | Unix seconds of the last message of any kind. |
| 5 | `longitude` | float | yes | WGS84 degrees. |
| 6 | `latitude` | float | yes | WGS84 degrees. |
| 7 | `baro_altitude` | float | yes | Barometric altitude, metres. |
| 8 | `on_ground` | boolean | no in the documented table | True when the position came from a surface position report. |
| 9 | `velocity` | float | yes | Ground speed, metres per second. |
| 10 | `true_track` | float | yes | Degrees clockwise from north. North is 0. |
| 11 | `vertical_rate` | float | yes | Metres per second. Positive is climb, negative is descent. |
| 12 | `sensors` | array of integers | yes | Receiver ids that contributed. Null when the request did not filter by sensor. A global or boxed `/states/all` therefore yields null. |
| 13 | `geo_altitude` | float | yes | Geometric altitude, metres. |
| 14 | `squawk` | string | yes | Transponder code. Documented examples are four-digit strings. Emergency codes used by the ADS-B demo are `7500`, `7600`, and `7700`. |
| 15 | `spi` | boolean | documented as a boolean flag | Special purpose indicator. |
| 16 | `position_source` | integer | documented as an enum | `0` ADS-B, `1` ASTERIX, `2` MLAT, `3` FLARM. The REST introduction says MLAT positions are **not** currently included, so `2` is defined and not expected on this API. |
| 17 | `category` | integer | only with `extended=1`; otherwise the element is absent | Emitter category. See enumeration below. |

`position_source` enumeration:

| Value | Meaning |
|------:|---------|
| 0 | ADS-B |
| 1 | ASTERIX |
| 2 | MLAT (defined, not currently returned by REST) |
| 3 | FLARM |

`category` enumeration (index 17):

| Value | Meaning |
|------:|---------|
| 0 | No information at all |
| 1 | No ADS-B Emitter Category Information |
| 2 | Light (< 15500 lbs) |
| 3 | Small (15500 to 75000 lbs) |
| 4 | Large (75000 to 300000 lbs) |
| 5 | High Vortex Large (for example B-757) |
| 6 | Heavy (> 300000 lbs) |
| 7 | High Performance (> 5 g and 400 knots) |
| 8 | Rotorcraft |
| 9 | Glider / sailplane |
| 10 | Lighter-than-air |
| 11 | Parachutist / skydiver |
| 12 | Ultralight / hang-glider / paraglider |
| 13 | Reserved |
| 14 | Unmanned aerial vehicle |
| 15 | Space / trans-atmospheric vehicle |
| 16 | Surface vehicle — emergency vehicle |
| 17 | Surface vehicle — service vehicle |
| 18 | Point obstacle (includes tethered balloons) |
| 19 | Cluster obstacle |
| 20 | Line obstacle |

Not in the API payload, but produced later by the ADS-B demo’s ingest pipeline (do not expect them from OpenSky):

- `location` geo_point built from latitude and longitude
- `geo.*` country/region attributes from a Natural Earth polygon enrich
- `airport.name`, `airport.iata_code`, `airport.gps_code`, `airport.activity` from an airport-proximity enrich
- `airport.activity` values in that demo: `at_airport`, `taxiing`, `arriving`, `departing`, `overflight`

## Flight object

Returned as a JSON array by all four `/flights/*` operations. Field names are camelCase, as listed on `FlightData.keys`. The REST HTML page does not repeat the property table (it says “each flight is an object with the following properties” and then stops). The inventory below is the official Python client, which is the complete published list.

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `icao24` | string | no | Lower-case hex transponder address. |
| `firstSeen` | integer | no | Estimated departure, Unix seconds. |
| `estDepartureAirport` | string | yes | ICAO code of the estimated departure airport. |
| `lastSeen` | integer | no | Estimated arrival, Unix seconds. |
| `estArrivalAirport` | string | yes | ICAO code of the estimated arrival airport. |
| `callsign` | string | yes | Up to 8 characters. If several callsigns were seen, OpenSky keeps the most frequent. Often space-padded. |
| `estDepartureAirportHorizDistance` | integer | documented with an example integer | Horizontal distance, metres, from the last airborne position to the estimated departure airport. |
| `estDepartureAirportVertDistance` | integer | same | Vertical distance, metres, to the estimated departure airport. |
| `estArrivalAirportHorizDistance` | integer | same | Horizontal distance, metres, to the estimated arrival airport. |
| `estArrivalAirportVertDistance` | integer | same | Vertical distance, metres, to the estimated arrival airport. |
| `departureAirportCandidatesCount` | integer | documented as a count | How many other airports sit near `estDepartureAirport`. |
| `arrivalAirportCandidatesCount` | integer | documented as a count | How many other airports sit near `estArrivalAirport`. |

No latitude, longitude, altitude, squawk, or operator name is on this object. Airport values are ICAO codes, not IATA codes.

There is no event-type discriminator. Arrival versus departure versus network-wide versus single-aircraft is entirely a function of which URL was called.

## Track object

`GET /tracks/all` returns one object.

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `icao24` | string | no | Lower-case hex. |
| `startTime` | integer | no | Unix seconds of the first waypoint. |
| `endTime` | integer | no | Unix seconds of the last waypoint. |
| `calllsign` | string | yes | Callsign for the whole track. The key is spelled `calllsign` (three `l`s) in the REST table and in `FlightTrack`. |
| `path` | array of arrays | empty array not documented; the client assumes a list | Waypoints. |

Waypoint array:

| Index | Name | Type | Nullable | Description |
|------:|------|------|----------|-------------|
| 0 | `time` | integer | no | Unix seconds. |
| 1 | `latitude` | float | yes | WGS84 degrees. |
| 2 | `longitude` | float | yes | WGS84 degrees. |
| 3 | `baro_altitude` | float | yes | Metres. |
| 4 | `true_track` | float | yes | Degrees clockwise from north. |
| 5 | `on_ground` | boolean | documented as boolean | Surface position report. |

## Timestamp summary

| Source | Unit | Time zone |
|--------|------|-----------|
| State envelope `time` | Unix seconds | UTC epoch |
| `time_position`, `last_contact` | Unix seconds | UTC epoch |
| Flight `firstSeen`, `lastSeen` | Unix seconds | UTC epoch |
| Track `startTime`, `endTime`, waypoint `time` | Unix seconds | UTC epoch |
| OAuth `expires_in` | seconds of lifetime, not a timestamp | n/a |

No ISO-8601 timestamps and no local-time strings appear in these payloads.
