# Sample events

These JSON files illustrate the OpenSky REST wire format. They are **[CONSTRUCTED EXAMPLES]** built from the field lists in the OpenSky REST API 1.4.0 documentation and `opensky_api.py` (`FlightData`, `StateVector`, `FlightTrack`, `Waypoint`). They are not captures from a live response.

Identifiers and timestamps that appear in the official documentation examples are reused where possible:

- `icao24=3c6444` and `time=1458564121` from the `/states/all` example
- `icao24=3c675a` and `begin=1517227200` / `end=1517230800` from the flights examples
- airport `EDDF` from the arrival/departure examples
- `icao24=3c4b26` from the tracks example

Numeric positions, altitudes, and flight-estimate distances are placeholders so every documented type is visible, including JSON `null`.
