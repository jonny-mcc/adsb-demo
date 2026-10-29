# Market coverage — OpenSky Network

Search date: 2026-10-28.

The product is the **OpenSky Network** air-traffic data service (`opensky-network.org`), not the unrelated companies and products that share the word “OpenSky” (OpenSky Data / openskydata.com, TÜV Rheinland OpenSky, DarkSky). Those name collisions were discarded.

Catalog starting points from the research checklist:

- IBM QRadar: `https://www.ibm.com/products/qradar-siem/integrations`
- Splunk: `https://splunkbase.splunk.com/apps`
- Sumo Logic: `https://www.sumologic.com/help/docs/integrations/`

Web search was used because the QRadar and Sumo catalog pages are directories rather than a queryable index, and Splunkbase search for the exact product name did not return an OpenSky Network app. Details that were not printed on a listing are marked `[UNVERIFIED]`.

## Summary table

| Platform | Integration name | Supported data sources | Collection method | Link |
|----------|------------------|------------------------|-------------------|------|
| IBM QRadar | No integration found | N/A | N/A | N/A |
| Splunk | No OpenSky Network integration. Near-miss only: AirSpace Watch TA polls a local dump1090/tar1090 receiver, not the OpenSky API. | N/A for OpenSky. The near-miss covers local ADS-B aircraft rows (hex, callsign, position). | N/A for OpenSky. Near-miss is a modular input HTTP poll of a local receiver. | N/A |
| Sumo Logic | No integration found | N/A | N/A | N/A |

## IBM QRadar

No Device Support Module, content extension, or app for the OpenSky Network was found.

Search terms tried: “OpenSky”, “OpenSky Network”, “ADS-B”, “OpenSky REST”. Results that matched “OpenSky” were other vendors, or IBM’s own QRadar SOAR add-on for Splunk (`https://splunkbase.splunk.com/app/6498`), which moves Splunk notables into QRadar SOAR and does not collect aircraft data.

Support tier: not applicable. Coverage of state vectors, flights, arrivals, departures, and tracks: none.

## Splunk

No Splunkbase app named for the OpenSky Network, and no technology add-on that documents the OpenSky REST API, Keycloak client credentials, or the `/states`, `/flights`, or `/tracks` resources.

Near-misses (different data source — a receiver on the collector’s network):

| App | Publisher | Version | Updated | URL | What it actually collects |
|-----|-----------|---------|---------|-----|---------------------------|
| AirSpace Watch TA (tar1090 / dump1090) | Will Searle | 1.0.0 | 2026-07-28 | https://splunkbase.splunk.com/app/9301 | Splunk modular input. Polls a **local** tar1090 or dump1090-fa receiver. One event per aircraft per poll. Developer supported. Splunk Enterprise and Splunk Cloud 9.4–10.6. Download count and star rating were not shown in the fetched listing. |
| Custom Viz - Airspace Radar | Will Searle | 1.0.7 | 2026-10-01 | https://splunkbase.splunk.com/app/8813 | Dashboard Studio visualisation. Expects rows with `hex`, `callsign`, `lat`, `lon`, `altitude_ft`, `heading`, `speed_kts`. It does not collect data. The listing says it pairs with AirSpace Watch. |

These near-misses are local ADS-B, not the OpenSky Network’s aggregated REST feed. They do not cover flights, arrivals, departures, tracks, OAuth2, or OpenSky credit limits. `[UNVERIFIED]` whether any private Splunk app outside Splunkbase wraps the OpenSky API; none is in the public catalog results.

## Sumo Logic

No Sumo Logic app or hosted collector for the OpenSky Network was found in the integrations documentation search.

False positives:

- Sumo Logic’s IBM QRadar automation integration (`https://www.sumologic.com/help/docs/integrations/automation-integrations/ibm-qradar/`, version 1.4, updated 2026-04-29) manages QRadar offenses. It is not an aircraft data source.
- Partner directories that mention “OpenSky” refer to other companies with that name.

Support tier: not applicable.

## Comparison

- None of the three SIEM catalogs collects OpenSky REST data.
- The only adjacent implementation is Splunk’s local-receiver poll (dump1090/tar1090), which is a different protocol and a different vantage point (one antenna, not the OpenSky network).
- Elastic’s integration repository has no `opensky` package (repository search hits were unrelated `network_traffic` packet capture). The ADS-B demo repositories are private demos, not Fleet packages.
- Gap an Elastic package would fill: authenticated OpenSky state vectors, flight intervals, and tracks, which none of QRadar, Splunk, or Sumo Logic cover.

## Sources

| Source | URL | Date |
|--------|-----|------|
| Splunkbase AirSpace Watch TA | https://splunkbase.splunk.com/app/9301 | 2026-10-28 |
| Splunkbase Airspace Radar viz | https://splunkbase.splunk.com/app/8813 | 2026-10-28 |
| Splunkbase QRadar SOAR add-on (name collision) | https://splunkbase.splunk.com/app/6498 | 2026-10-28 |
| Sumo Logic QRadar automation (name collision) | https://www.sumologic.com/help/docs/integrations/automation-integrations/ibm-qradar/ | 2026-10-28 |
| OpenSky data access overview | https://opensky-network.org/data/ | 2026-10-28 |
