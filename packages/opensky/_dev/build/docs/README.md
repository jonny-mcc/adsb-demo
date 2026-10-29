{{- generatedHeader }}
{{/*
This template can be used as a starting point for writing documentation for your new integration. For each section, fill in the details
described in the comments.

Find more detailed documentation guidelines in https://www.elastic.co/docs/extend/integrations/documentation-guidelines
*/}}
# OpenSky Network Integration for Elastic

## Overview
{{/* Complete this section with a short summary of what data this integration collects and the service it integrates with. */}}
The OpenSky Network integration collects live and recent aircraft surveillance from the [OpenSky Network REST API](https://openskynetwork.github.io/opensky-api/rest.html). OpenSky aggregates ADS-B and related broadcasts from a community receiver network. This integration polls that API for state vectors, estimated flight intervals, and experimental tracks.

A local dump1090 or tar1090 receiver is a different data source and is not collected here. The OpenSky Trino warehouse is also out of scope.

### Compatibility
{{/* Complete this section with information on what 3rd party software or hardware versions this integration is compatible with */}}
This integration is compatible with OpenSky Network REST API documentation set 1.4.0. The API path is unversioned. Authentication is OAuth2 client credentials against the OpenSky Keycloak token endpoint. Anonymous access is not a supported configuration: flights and tracks require a client, and anonymous state history ignores the `time` parameter.

### How it works

Elastic Agent uses the CEL input to request an access token, then polls the configured OpenSky endpoint on an interval. State vectors and track waypoints are positional JSON arrays. Flights are JSON objects. Each poll publishes one document per state vector, one document per flight, or one document per track waypoint.

There is no pagination cursor. A flight response of HTTP 404 with an empty body means the interval contained no flights.

## What data does this integration collect?
{{/* Complete this section with information on what types of data the integration collects, and link to reference documentation if available
*/}}
The OpenSky Network integration collects the following types:
* State vectors from `GET /states/all` or `GET /states/own`
* Flights from `GET /flights/all`, `GET /flights/aircraft`, `GET /flights/arrival`, or `GET /flights/departure`
* Track waypoints from `GET /tracks/all`

### Supported use cases
{{/* Add details on the use cases that can be enabled by using this integration. Explain why a user would want to install and use this integration. */}}
Operators and researchers can search recent aircraft positions, callsigns, squawk codes, and estimated airport movements without running a receiver. Use a bounding box or an extra policy instance when a global state poll is larger than you need. Flight and track credits are separate from state credits, so those streams can run on their own intervals.

## What do I need to use this integration?
{{/* List any Elastic or vendor-specific prerequisites needed before starting to install the integration. For example, Elastic self-managed or cloud deployment, or a vendor-specific credentials or accounts */}}
* An Elastic deployment and an Elastic Agent enrolled in Fleet, or a standalone agent.
* An OpenSky Network account with an API client (`client_id` and `client_secret`).
* Outbound HTTPS to `opensky-network.org` and `auth.opensky-network.org`.
* Enough daily credits for the chosen interval and bounding box. A global `/states/all` call costs 4 state credits. The standard account refills 4,000 state credits per day.
* For own-receiver state vectors, the account must own receivers. Otherwise `/states/own` returns HTTP 403.

## How do I deploy this integration?

### Agent-based deployment

Elastic Agent must be installed. For more details, check the Elastic Agent [installation instructions](https://www.elastic.co/guide/en/fleet/current/elastic-agent-installation.html). You can install only one Elastic Agent per host.

Elastic Agent polls the OpenSky REST API and ships the documents to Elastic, where the events are processed by the integration's ingest pipelines. A global state response can be tens of megabytes. Allow the agent a large response body (about 50 MiB) and a timeout of at least 90 seconds.

{{/* If agentless is available for this integration, include the following section. You can determine if agentless is available for this integration by checking the `manifest.yml` file, and looking for the existence of `policy_templates.deployment_modes.agentless.enabled: "true"`.
### Agentless deployment

Agentless deployments are only supported in Elastic Serverless and Elastic Cloud environments. Agentless deployments provide a means to ingest data while avoiding the orchestration, management, and maintenance needs associated with standard ingest infrastructure. Using an agentless deployment makes manual agent deployment unnecessary, allowing you to focus on your data instead of the agent that collects it.

For more information, refer to [Agentless integrations](https://www.elastic.co/guide/en/serverless/current/security-agentless-integrations.html) and [Agentless integrations FAQ](https://www.elastic.co/guide/en/serverless/current/agentless-integration-troubleshooting.html) 
*/}}

### Set up steps in OpenSky Network
{{/* List the steps that are required to set up the 3rd party system to send data to Elastic. 
This should be specific to the steps needed to set up the 3rd party system to send data to Elastic. It should not include generic information about how to install or set up the 3rd party system itself.
*/}}
1. Create an OpenSky Network account and open the account page.
2. Create an API client and record the client ID and client secret.
3. Accept the OpenSky terms of use. No OAuth scope is required.

#### Vendor resources
{{/* Add vendor documentation links that are specific to the steps needed to set up the vendor system to send data to Elastic. Exclude this section if no vendor setup links are available. */}}
- [OpenSky REST API](https://openskynetwork.github.io/opensky-api/rest.html)
- [OpenSky data access](https://opensky-network.org/data/)
- [OpenSky terms of use](https://opensky-network.org/about/terms-of-use)

### Set up steps in Kibana
{{/* List the steps that are required to set up the integration in Kibana.
This includes how to add the integration, and how to configure the integration, with descriptions of each available configuration option.

If multiple input types are supported, add instructions for each in a subsection.
*/}}
1. In Kibana, go to **Integrations** and search for **OpenSky Network**.
2. Add the integration to an agent policy.
3. Set the API URL, client ID, client secret, and token URL. The defaults match the public OpenSky hosts.
4. Enable the data streams you need:
   * **State vector** polls `/states/all` every 6 minutes unless you select own receivers only. Optionally set a WGS84 box (`lamin`, `lamax`, `lomin`, `lomax`) or an ICAO24 filter. Leave the box empty for a global poll. `extended` defaults to true so the aircraft category is included.
   * **Flight** polls one of `all`, `aircraft`, `arrival`, or `departure`. `all` uses a two-hour window. `aircraft` needs a lower-case ICAO24 address. `arrival` and `departure` need an airport ICAO code.
   * **Track** polls `/tracks/all` for one lower-case ICAO24 address. `time` of 0 means the live track. Tracks are experimental and return one aircraft per request.
5. Save and deploy the policy.

### Validation
{{/* In this section, describe the actions required to validate that the integration is working properly, and data is flowing into Elasticsearch.
If required, list the steps needed in the vendor product to start sending events or trigger alerts.
Then list how to validate that the data is in Elasticsearch, using Kibana. This could be which indices to check in the Discover table, or which built in dashboards to look at to see the data.
*/}}
In Discover, select the data view `logs-opensky.*`. A healthy state-vector poll shows documents with `event.dataset: opensky.state_vector` within one interval. Flight documents use `opensky.flight`. Track documents use `opensky.track`.

If state vectors stay empty, confirm the client can obtain a token and that the account still has state credits. HTTP 429 means the credit bucket is exhausted until `X-Rate-Limit-Retry-After-Seconds` elapses. HTTP 404 on a flight poll with an empty body means that window had no flights.

## Troubleshooting
{{/* The troubleshooting section should contain troubleshooting for common issues specific to this integration. Do not include generic troubleshooting information. Where appropriate, include details specific to each input type.
Whenever possible, link to the troubleshooting documentation provided by the third-party software. 

IMPORTANT: Use plain text for issue descriptions, NOT bold. Example:
- No data is being collected: Verify network connectivity and credentials
- TCP framing issues: Check that both sides use the same framing method
Do NOT use **bold** for issue names like "**No data is being collected**:".
*/}}
- No documents after the first interval: Confirm outbound HTTPS to both `opensky-network.org` and `auth.opensky-network.org`, and that the client ID and secret belong to an API client rather than the account password. Basic authentication is no longer accepted.
- HTTP 400 on state vectors: An authenticated `time` older than one hour is rejected. Keep the initial lookback inside that hour.
- HTTP 403 on own receivers: `/states/own` only returns data for accounts that own receivers.
- HTTP 404 on flights: An empty 404 body means there were no flights in the window. It is not a bad URL.
- Large or timed-out state polls: A global response needs a long timeout and a large agent body limit. Narrow the box, or add another state-vector instance per region. A hemisphere box costs the same 4 credits as one global call.
- Repeated flight documents: Overlapping windows can return the same `icao24` and `firstSeen` again. There is no separate flight ID.

## Performance and scaling
{{/* Add any vendor specific performance and scaling information to this section.
Performance and scaling information should be specific to sending data to Elasticsearch. It should not include information about the vendor product itself or generic information about performance and scaling.
*/}}
State credits, flight credits, and track credits are independent. A global state poll every 6 minutes uses about 960 state credits per day. Four hemisphere quadrants every 6 minutes use about 3,840, close to the standard 4,000 daily cap, and do not reduce the per-call cost below a single global poll. Prefer one global poll or a small box.

Flights and tracks that cover a live or sub-24-hour range cost 4 credits in their own bucket. Wider historical ranges cost more. `/tracks/all` is one aircraft per request. Airport arrival and departure data is produced in a nightly batch and does not include the current UTC day.

For more information on architectures that can be used for scaling this integration, check the [Ingest Architectures](https://www.elastic.co/docs/manage-data/ingest/ingest-reference-architectures) documentation.

## Reference

### Inputs used
{{/* All inputs used by this package will be automatically listed here. Do not modify this section. */}}
{{ inputDocs }}

### API usage
{{/* For integrations that use APIs to collect data, document all the APIs that are used, and link to relevent information. For integrations that do not use APIs, do not include this section. */}}
These APIs are used with this integration:
* `POST` token URL (default `https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token`) with grant type `client_credentials`
* `GET /states/all` and, when own receivers is enabled, `GET /states/own`
* `GET /flights/all`, `GET /flights/aircraft`, `GET /flights/arrival`, and `GET /flights/departure`
* `GET /tracks/all` (the REST heading says `/tracks`; the published client calls `/tracks/all`)

Credit and parameter details are in the [OpenSky REST API documentation](https://openskynetwork.github.io/opensky-api/rest.html).

### Vendor documentation links
{{/* Add vendor documentation links which provide useful general information about the integration.*/}}
- [OpenSky REST API](https://openskynetwork.github.io/opensky-api/rest.html)
- [OpenSky Python client](https://github.com/openskynetwork/opensky-api/blob/master/python/opensky_api.py)
- [OpenSky terms of use](https://opensky-network.org/about/terms-of-use)

### Data streams
{{/* Repeat all information in this section for each data stream the package collects.*/}}

#### state_vector

The `state_vector` data stream provides one event per aircraft in a state response. Positions, altitudes, velocity, squawk, and category come from the positional array. `origin_country` is the ICAO address allocation country, not the country under the aircraft.

##### state_vector fields

{{ fields "state_vector" }}

##### state_vector sample event

{{ event "state_vector" }}

#### flight

The `flight` data stream provides one event per flight object. The four flight endpoints share one schema. Which endpoint is called depends on the flight scope.

##### flight fields

{{ fields "flight" }}

##### flight sample event

{{ event "flight" }}

#### track

The `track` data stream provides one event per waypoint. The track callsign field on the wire is spelled `calllsign`.

##### track fields

{{ fields "track" }}

##### track sample event

{{ event "track" }}

{{/* Export ILM Policies
     This accepts a list of data stream names as arguments and documents one policy
     per data stream. If no arguments are provided, data streams are auto-discovered by
     scanning for data_stream/<name>/elasticsearch/ilm/ directories and
     data_stream/<name>/lifecycle.yml files (lifecycle.yml takes precedence when both exist).

     If there are no policies defined, this renders as an empty string (no heading).
*/}}
{{ ilm }}

{{/* Export Transforms
     This will export the transforms used by this integration.
     If there are no transforms defined, this renders as an empty string (no heading).
*/}}
{{ transform }}
