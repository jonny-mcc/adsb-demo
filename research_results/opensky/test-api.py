#!/usr/bin/env python3
"""
OpenSky Network — API Connectivity & Flow Test
==============================================

Exercises the OpenSky REST flow proposed for the Elastic CEL integration:
OAuth2 client-credentials, then GET /states/all, GET /flights/all (HTTP 404
with an empty body means an empty window), and GET /tracks/all when an
ICAO24 address is supplied.

Vendor-side setup
-----------------
1. Create an account at https://opensky-network.org and open the account page.
2. Create an API client. Copy the client id and client secret.
3. No OAuth scope is documented. Do not send one.
4. The token host (auth.opensky-network.org) and the API host
   (opensky-network.org) both need outbound HTTPS.
5. Credits are limited. A global /states/all call costs 4 state-bucket
   credits. Each /flights/all window under 24 hours costs 4 flight-bucket
   credits. /tracks/all costs 4 track-bucket credits. This script stops
   after --max-pages flight windows so a test cannot walk the calendar.

Usage
-----
    python3 test-api.py --client-id ID --client-secret SECRET

    Environment variables (CLI flags win when both are set):
        OPENSKY_CLIENT_ID      OAuth2 client id
        OPENSKY_CLIENT_SECRET  OAuth2 client secret
        OPENSKY_URL            API root (default https://opensky-network.org/api)
        OPENSKY_TOKEN_URL      Token endpoint
        OPENSKY_ICAO24         Lower-case hex address for /tracks/all and an
                               optional /states/all filter
        HTTPS_PROXY            Proxy URL (or --proxy)

Optional flags:
    --url              API root, scheme included
    --token-url        Client-credentials token URL
    --icao24           Aircraft address. Tracks are skipped when this is omitted
    --lamin/--lamax/--lomin/--lomax
                       Optional WGS84 box. All four or none
    --no-extended      Do not send extended=1 (category column omitted)
    --max-pages        Flight windows to try, newest first (default 5)
    --timeout          HTTP timeout seconds (default 90; global state bodies
                       are large)
    --proxy            HTTP(S) proxy URL
    --output-dir       Directory for test-api.log and trace.json
    --mock             Do not write a .tar.gz; print the output directory

Output
------
On success the script creates an output directory containing:
    test-api.log             — verbose step-by-step log
    trace.json               — detailed request/response trace (auth redacted)

The directory is then archived as <output-dir>.tar.gz.
Please send this archive to the integration maintainers for review.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import ssl
import sys
import tarfile
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_API_URL = "https://opensky-network.org/api"
DEFAULT_TOKEN_URL = (
    "https://auth.opensky-network.org/auth/realms/opensky-network/"
    "protocol/openid-connect/token"
)
FLIGHT_WINDOW_SECONDS = 7200
LOG = logging.getLogger("opensky-test-api")


def redact(value):
    """Replace a secret with a fixed marker. Non-strings pass through."""
    if value is None or value == "":
        return value
    return "[REDACTED]"


def redact_dict(obj):
    """Return a copy of a JSON-like structure with known secrets removed."""
    secret_keys = {
        "access_token",
        "refresh_token",
        "id_token",
        "client_secret",
        "clientSecret",
    }
    if isinstance(obj, dict):
        cleaned = {}
        for key, item in obj.items():
            if key in secret_keys and item:
                cleaned[key] = "[REDACTED]"
            elif key.lower() == "authorization":
                cleaned[key] = "[REDACTED]"
            else:
                cleaned[key] = redact_dict(item)
        return cleaned
    if isinstance(obj, list):
        return [redact_dict(item) for item in obj]
    return obj


def redact_headers(headers):
    """Copy headers with Authorization removed."""
    cleaned = {}
    for key, value in headers.items():
        if key.lower() == "authorization":
            cleaned[key] = "[REDACTED]"
        else:
            cleaned[key] = value
    return cleaned


def _try_parse_body(text):
    """Return parsed JSON if *text* is JSON, otherwise the string.

    OAuth token fields are redacted when the body is an object.
    """
    if not text:
        return text
    try:
        obj = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return redact(text) if "access_token" in text else text
    return redact_dict(obj)


def mask_tail(value):
    """Show only the last four characters of a credential."""
    if not value:
        return "(not set)"
    if len(value) <= 4:
        return "****"
    return "****" + value[-4:]


class HttpResult:
    """One completed HTTP exchange, including transport failures."""

    def __init__(self, method, url, req_headers, req_body, status, resp_headers, resp_text, elapsed, error):
        self.method = method
        self.url = url
        self.req_headers = req_headers
        self.req_body = req_body
        self.status = status
        self.resp_headers = resp_headers
        self.resp_text = resp_text
        self.elapsed = elapsed
        self.error = error


def do_request(method, url, headers, body_bytes, timeout, proxy):
    """Perform one HTTP call with TLS verification disabled."""
    context = ssl._create_unverified_context()
    handlers = [urllib.request.HTTPSHandler(context=context)]
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    opener = urllib.request.build_opener(*handlers)
    request = urllib.request.Request(url, data=body_bytes, headers=headers, method=method)
    started = time.monotonic()
    try:
        with opener.open(request, timeout=timeout) as response:
            raw = response.read()
            elapsed = time.monotonic() - started
            text = raw.decode("utf-8", errors="replace")
            resp_headers = {key: value for key, value in response.headers.items()}
            return HttpResult(method, url, headers, body_bytes, response.status, resp_headers, text, elapsed, None)
    except urllib.error.HTTPError as exc:
        elapsed = time.monotonic() - started
        raw = exc.read() if exc.fp is not None else b""
        text = raw.decode("utf-8", errors="replace")
        resp_headers = {key: value for key, value in exc.headers.items()} if exc.headers else {}
        return HttpResult(method, url, headers, body_bytes, exc.code, resp_headers, text, elapsed, None)
    except Exception as exc:  # connection errors, timeouts, URL errors
        elapsed = time.monotonic() - started
        return HttpResult(method, url, headers, body_bytes, None, {}, "", elapsed, str(exc))


def rate_limit_notes(headers):
    """Return the two credit headers OpenSky documents, when present."""
    wanted = ("X-Rate-Limit-Remaining", "X-Rate-Limit-Retry-After-Seconds", "Retry-After")
    found = {}
    folded = {key.lower(): value for key, value in headers.items()}
    for name in wanted:
        if name.lower() in folded:
            found[name] = folded[name.lower()]
    return found


def request_body_for_trace(body_bytes):
    """Parse a request body for the trace. Form secrets never stay in the clear."""
    if not body_bytes:
        return None
    text = body_bytes.decode("utf-8", errors="replace")
    if "client_secret=" in text or text.startswith("grant_type="):
        pairs = urllib.parse.parse_qs(text, keep_blank_values=True)
        cleaned = {}
        for key, values in pairs.items():
            shown = values[0] if len(values) == 1 else values
            if key in ("client_secret", "clientSecret"):
                shown = "[REDACTED]"
            cleaned[key] = shown
        return cleaned
    return _try_parse_body(text)


def trace_entry(page, result, pagination, event_count, error):
    """Build one trace.json element. Secrets are already redacted."""
    body_obj = request_body_for_trace(result.req_body)
    return {
        "page": page,
        "request": {
            "method": result.method,
            "url": result.url,
            "headers": redact_headers(result.req_headers),
            "body": body_obj,
        },
        "response": {
            "status_code": result.status,
            "headers": dict(result.resp_headers),
            "body": _try_parse_body(result.resp_text),
            "elapsed_s": round(result.elapsed, 3),
        },
        "pagination": pagination,
        "event_count": event_count,
        "error": error,
    }


def fetch_token(token_url, client_id, client_secret, timeout, proxy, trace):
    """POST the client-credentials grant. Same token request the collection uses."""
    form = urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
        }
    ).encode("utf-8")
    headers = {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
    result = do_request("POST", token_url, headers, form, timeout, proxy)
    notes = rate_limit_notes(result.resp_headers)
    LOG.debug(
        "token status=%s elapsed=%.3fs notes=%s",
        result.status,
        result.elapsed,
        notes,
    )
    parsed = _try_parse_body(result.resp_text)
    error = result.error
    token = None
    if result.status == 200 and isinstance(parsed, dict):
        # Read the token from the raw body, then store only the redacted copy.
        try:
            raw_obj = json.loads(result.resp_text)
        except (json.JSONDecodeError, ValueError):
            raw_obj = {}
        token = raw_obj.get("access_token")
        if not token:
            error = "token response missing access_token"
    elif result.status == 429:
        error = "token endpoint returned 429: %s" % notes
    elif error is None:
        error = "token request failed with HTTP %s" % result.status
    pagination = {
        "mechanism": "none",
        "field_used": None,
        "value_from_response": None,
        "value_for_next_request": None,
        "want_more": False,
    }
    trace.append(trace_entry(0, result, pagination, 0, error))
    return token, result, error


def states_url(api_url, icao24, bbox, extended):
    """Build GET /states/all. Same query the state_vector collection sends."""
    params = []
    if extended:
        params.append(("extended", "1"))
    if icao24:
        params.append(("icao24", icao24.lower()))
    if bbox is not None:
        lamin, lamax, lomin, lomax = bbox
        params.extend(
            (
                ("lamin", str(lamin)),
                ("lomin", str(lomin)),
                ("lamax", str(lamax)),
                ("lomax", str(lomax)),
            )
        )
    query = urllib.parse.urlencode(params)
    url = api_url.rstrip("/") + "/states/all"
    if query:
        url = url + "?" + query
    return url


def count_states(parsed):
    if isinstance(parsed, dict) and isinstance(parsed.get("states"), list):
        return len(parsed["states"])
    return 0


def count_flights(parsed):
    if isinstance(parsed, list):
        return len(parsed)
    return 0


def count_waypoints(parsed):
    if isinstance(parsed, dict) and isinstance(parsed.get("path"), list):
        return len(parsed["path"])
    return 0


def run_collection(args, trace):
    """Token, one state snapshot, then flight windows, then an optional live track.

    Flight windows walk backward by two hours, which is the maximum
    /flights/all interval. HTTP 404 is an empty window and the script tries
    an older window until --max-pages. A non-empty 200 stops the walk.
    """
    stats = {
        "states": 0,
        "flights": 0,
        "waypoints": 0,
        "flight_pages": 0,
        "flight_404s": 0,
    }
    failures = []

    print("[1] Requesting OAuth2 client-credentials token…")
    LOG.info("Requesting OAuth2 client-credentials token")
    token, token_result, token_error = fetch_token(
        args.token_url, args.client_id, args.client_secret, args.timeout, args.proxy, trace
    )
    if token_error or not token:
        message = token_error or "no access token"
        print("[1] FAILED (%s, %.2fs)" % (message, token_result.elapsed))
        LOG.error("token failed: %s", message)
        failures.append(message)
        return stats, failures
    print("[1] OK (token issued, %.2fs)" % token_result.elapsed)
    LOG.info("token issued in %.3fs", token_result.elapsed)

    auth_headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
    }

    state_target = states_url(args.url, args.icao24, args.bbox, args.extended)
    print("[2] Requesting /states/all…")
    LOG.info("GET %s", state_target)
    state_result = do_request("GET", state_target, auth_headers, None, args.timeout, args.proxy)
    state_notes = rate_limit_notes(state_result.resp_headers)
    LOG.debug("states status=%s notes=%s", state_result.status, state_notes)
    state_parsed = _try_parse_body(state_result.resp_text)
    state_count = count_states(state_parsed) if state_result.status == 200 else 0
    state_error = state_result.error
    if state_result.status == 429:
        state_error = "states returned 429: %s" % state_notes
    elif state_result.status != 200 and state_error is None:
        state_error = "states failed with HTTP %s" % state_result.status
    trace.append(
        trace_entry(
            1,
            state_result,
            {
                "mechanism": "none",
                "field_used": "states",
                "value_from_response": state_count,
                "value_for_next_request": None,
                "want_more": False,
            },
            state_count,
            state_error,
        )
    )
    if state_error:
        print("[2] FAILED (%s, %.2fs)" % (state_error, state_result.elapsed))
        LOG.error("states failed: %s", state_error)
        failures.append(state_error)
        return stats, failures
    stats["states"] = state_count
    print("[2] OK (%d aircraft, %.2fs)" % (state_count, state_result.elapsed))
    LOG.info("states aircraft=%d remaining=%s", state_count, state_notes.get("X-Rate-Limit-Remaining"))

    # Newest complete-enough window ends shortly before now. Each step is
    # exactly two hours, the /flights/all maximum.
    window_end = int(time.time()) - 120
    for page in range(1, args.max_pages + 1):
        window_begin = window_end - FLIGHT_WINDOW_SECONDS
        flight_target = args.url.rstrip("/") + "/flights/all?" + urllib.parse.urlencode(
            {"begin": str(window_begin), "end": str(window_end)}
        )
        label = "[3.%d/%d]" % (page, args.max_pages)
        print("%s Requesting /flights/all begin=%d end=%d…" % (label, window_begin, window_end))
        LOG.info("GET %s", flight_target)
        flight_result = do_request("GET", flight_target, auth_headers, None, args.timeout, args.proxy)
        flight_notes = rate_limit_notes(flight_result.resp_headers)
        LOG.debug("flights status=%s notes=%s", flight_result.status, flight_notes)
        flight_error = flight_result.error
        empty = flight_result.status == 404
        flight_parsed = _try_parse_body(flight_result.resp_text)
        flight_count = count_flights(flight_parsed) if flight_result.status == 200 else 0
        if flight_result.status == 429:
            flight_error = "flights returned 429: %s" % flight_notes
        elif flight_result.status not in (200, 404) and flight_error is None:
            flight_error = "flights failed with HTTP %s" % flight_result.status
        want_more = empty and page < args.max_pages and flight_error is None
        next_end = window_begin if want_more else None
        trace.append(
            trace_entry(
                page,
                flight_result,
                {
                    "mechanism": "time-window",
                    "field_used": "http_status" if empty else "begin/end",
                    "value_from_response": flight_result.status,
                    "value_for_next_request": {"begin": next_end - FLIGHT_WINDOW_SECONDS, "end": next_end}
                    if next_end is not None
                    else None,
                    "want_more": want_more,
                },
                flight_count,
                flight_error,
            )
        )
        stats["flight_pages"] += 1
        if flight_error:
            print("%s FAILED (%s, %.2fs)" % (label, flight_error, flight_result.elapsed))
            LOG.error("flights failed: %s", flight_error)
            failures.append(flight_error)
            return stats, failures
        if empty:
            stats["flight_404s"] += 1
            print("%s OK (HTTP 404 empty window, %.2fs)" % (label, flight_result.elapsed))
            LOG.info("flights 404 empty window %d-%d", window_begin, window_end)
            window_end = window_begin
            continue
        stats["flights"] += flight_count
        print("%s OK (%d flights, %.2fs)" % (label, flight_count, flight_result.elapsed))
        LOG.info("flights count=%d window=%d-%d", flight_count, window_begin, window_end)
        break

    if not args.icao24:
        print("[4] Skipping /tracks/all (no ICAO24 address)")
        LOG.info("tracks skipped; OPENSKY_ICAO24 / --icao24 not set")
        return stats, failures

    track_target = args.url.rstrip("/") + "/tracks/all?" + urllib.parse.urlencode(
        {"icao24": args.icao24.lower(), "time": "0"}
    )
    print("[4] Requesting /tracks/all icao24=%s time=0…" % args.icao24.lower())
    LOG.info("GET %s", track_target)
    track_result = do_request("GET", track_target, auth_headers, None, args.timeout, args.proxy)
    track_notes = rate_limit_notes(track_result.resp_headers)
    LOG.debug("tracks status=%s notes=%s", track_result.status, track_notes)
    track_parsed = _try_parse_body(track_result.resp_text)
    waypoint_count = count_waypoints(track_parsed) if track_result.status == 200 else 0
    track_error = track_result.error
    # 404 is not documented for tracks. Record it as an empty result so the
    # trace can answer that open question, and do not fail the run.
    if track_result.status == 404:
        print("[4] OK (HTTP 404, no live track documented contract, %.2fs)" % track_result.elapsed)
        LOG.info("tracks 404 body_length=%d", len(track_result.resp_text or ""))
    elif track_result.status == 429:
        track_error = "tracks returned 429: %s" % track_notes
    elif track_result.status != 200 and track_error is None:
        track_error = "tracks failed with HTTP %s" % track_result.status
    wire_keys = sorted(track_parsed.keys()) if isinstance(track_parsed, dict) else []
    trace.append(
        trace_entry(
            1,
            track_result,
            {
                "mechanism": "none",
                "field_used": "path",
                "value_from_response": waypoint_count,
                "value_for_next_request": None,
                "want_more": False,
                "object_keys": wire_keys,
            },
            waypoint_count,
            track_error,
        )
    )
    if track_error:
        print("[4] FAILED (%s, %.2fs)" % (track_error, track_result.elapsed))
        LOG.error("tracks failed: %s", track_error)
        failures.append(track_error)
        return stats, failures
    stats["waypoints"] = waypoint_count
    if track_result.status == 200:
        callsign_key = "calllsign" if isinstance(track_parsed, dict) and "calllsign" in track_parsed else "callsign-key-absent"
        print("[4] OK (%d waypoints, callsign key %s, %.2fs)" % (waypoint_count, callsign_key, track_result.elapsed))
        LOG.info("tracks waypoints=%d keys=%s", waypoint_count, wire_keys)
    return stats, failures


def write_outputs(output_dir, trace):
    """Write trace.json next to the log file the logger already holds open."""
    trace_path = os.path.join(output_dir, "trace.json")
    with open(trace_path, "w", encoding="utf-8") as handle:
        json.dump(trace, handle, indent=2, sort_keys=False)
        handle.write("\n")
    return trace_path


def archive_dir(output_dir):
    """Compress the output directory. Returns the archive path or None."""
    archive_path = output_dir.rstrip("/") + ".tar.gz"
    try:
        with tarfile.open(archive_path, "w:gz") as tar:
            tar.add(output_dir, arcname=os.path.basename(output_dir))
        return archive_path
    except Exception:
        LOG.exception("failed to create archive")
        return None


def parse_bbox(args):
    """Return a (lamin, lamax, lomin, lomax) tuple or None. All four or none."""
    edges = (args.lamin, args.lamax, args.lomin, args.lomax)
    if all(value is None for value in edges):
        return None
    if any(value is None for value in edges):
        raise SystemExit("Bounding box needs all of --lamin, --lamax, --lomin, and --lomax")
    lamin, lamax, lomin, lomax = edges
    if not (-90 <= lamin <= 90 and -90 <= lamax <= 90 and -180 <= lomin <= 180 and -180 <= lomax <= 180):
        raise SystemExit("Bounding box is outside WGS84 latitude/longitude limits")
    if lamin >= lamax:
        raise SystemExit("--lamin must be less than --lamax")
    return lamin, lamax, lomin, lomax


def build_parser():
    parser = argparse.ArgumentParser(description="Exercise the OpenSky REST flow used by the integration")
    parser.add_argument("--client-id", default=os.environ.get("OPENSKY_CLIENT_ID"))
    parser.add_argument("--client-secret", default=os.environ.get("OPENSKY_CLIENT_SECRET"))
    parser.add_argument("--url", default=os.environ.get("OPENSKY_URL", DEFAULT_API_URL))
    parser.add_argument("--token-url", default=os.environ.get("OPENSKY_TOKEN_URL", DEFAULT_TOKEN_URL))
    parser.add_argument("--icao24", default=os.environ.get("OPENSKY_ICAO24"))
    parser.add_argument("--lamin", type=float, default=None)
    parser.add_argument("--lamax", type=float, default=None)
    parser.add_argument("--lomin", type=float, default=None)
    parser.add_argument("--lomax", type=float, default=None)
    parser.add_argument("--no-extended", action="store_true")
    parser.add_argument("--max-pages", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--proxy", default=os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy"))
    parser.add_argument("--output-dir", default="test-api-output")
    parser.add_argument("--mock", action="store_true")
    return parser


def configure_logging(output_dir):
    """Log file at DEBUG. The console stays on the explicit print() lines."""
    LOG.setLevel(logging.DEBUG)
    LOG.handlers.clear()
    path = os.path.join(output_dir, "test-api.log")
    file_handler = logging.FileHandler(path, encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    LOG.addHandler(file_handler)
    return path


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.client_id or not args.client_secret:
        print("OPENSKY_CLIENT_ID and OPENSKY_CLIENT_SECRET (or --client-id and --client-secret) are required", file=sys.stderr)
        return 1
    if args.max_pages < 1:
        print("--max-pages must be at least 1", file=sys.stderr)
        return 1
    args.extended = not args.no_extended
    try:
        args.bbox = parse_bbox(args)
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 1

    os.makedirs(args.output_dir, exist_ok=True)
    log_path = configure_logging(args.output_dir)
    print("OpenSky Network API connectivity test")
    print("API URL:      %s" % args.url)
    print("Token URL:    %s" % args.token_url)
    print("Client id:    %s" % mask_tail(args.client_id))
    print("Client secret:%s" % mask_tail(args.client_secret))
    print("ICAO24:       %s" % (args.icao24.lower() if args.icao24 else "(tracks skipped)"))
    print("Bounding box: %s" % (args.bbox if args.bbox else "(global — 4 state credits)"))
    print("extended:     %s" % args.extended)
    print("max pages:    %d" % args.max_pages)
    print("timeout:      %ss" % args.timeout)
    print("output:       %s" % os.path.abspath(args.output_dir))
    LOG.info(
        "config url=%s token_url=%s client_id=%s icao24=%s bbox=%s extended=%s max_pages=%s timeout=%s proxy=%s",
        args.url,
        args.token_url,
        mask_tail(args.client_id),
        args.icao24,
        args.bbox,
        args.extended,
        args.max_pages,
        args.timeout,
        bool(args.proxy),
    )

    trace = []
    exit_code = 0
    stats = {"states": 0, "flights": 0, "waypoints": 0, "flight_pages": 0, "flight_404s": 0}
    failures = []
    try:
        stats, failures = run_collection(args, trace)
        if failures:
            exit_code = 1
    except KeyboardInterrupt:
        LOG.warning("interrupted")
        print("Interrupted. Writing what was captured.")
        failures.append("interrupted")
        exit_code = 1
    except Exception:
        LOG.error("unhandled exception\n%s", traceback.format_exc())
        print("FAILED (unhandled exception; see test-api.log)")
        failures.append("unhandled exception")
        exit_code = 1
    finally:
        try:
            write_outputs(args.output_dir, trace)
        except Exception:
            LOG.exception("failed to write trace.json")
            exit_code = 1

    status = "SUCCESS" if exit_code == 0 else "FAILED"
    print("")
    print("Status:          %s" % status)
    print("Aircraft:        %d" % stats["states"])
    print("Flights:         %d" % stats["flights"])
    print("Flight windows:  %d (%d empty 404s)" % (stats["flight_pages"], stats["flight_404s"]))
    print("Track waypoints: %d" % stats["waypoints"])
    if failures:
        print("Errors:          %s" % "; ".join(failures))
    print("Log:             %s" % os.path.abspath(log_path))
    LOG.info(
        "summary status=%s aircraft=%s flights=%s windows=%s empty=%s waypoints=%s",
        status,
        stats["states"],
        stats["flights"],
        stats["flight_pages"],
        stats["flight_404s"],
        stats["waypoints"],
    )
    for handler in LOG.handlers:
        handler.flush()

    if args.mock:
        print("Mock mode: archive skipped.")
        print("Output directory: %s" % os.path.abspath(args.output_dir))
        print("Results are in test-api.log and trace.json.")
    else:
        archive_path = archive_dir(args.output_dir)
        if archive_path:
            print("Archive:         %s" % os.path.abspath(archive_path))
            print("Please send this archive to the integration maintainers for review.")
        else:
            print("Archive failed. Unarchived directory: %s" % os.path.abspath(args.output_dir))
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
