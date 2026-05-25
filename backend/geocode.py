"""
Address → (lat, lng) via the US Census Geocoder.

Free, no API key, US-only (which matches v1's US-only scope). The Census
Bureau runs this for free with generous rate limits and excellent coverage
of US residential addresses. Failures are non-fatal — we fall back to the
backend's default coordinates and weather still works (just for a slightly
wrong location).

API shape:
    GET https://geocoding.geo.census.gov/geocoder/locations/onelineaddress
        ?address=<full address>
        &benchmark=Public_AR_Current
        &format=json
Response: {"result": {"addressMatches": [{"coordinates": {"x": LON, "y": LAT}, ...}]}}
"""

from __future__ import annotations

import requests

CENSUS_BASE = "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress"
HEADERS = {
    "User-Agent": "captain-app/0.1",
    "Accept": "application/json",
}

# Small in-memory cache so repeat lookups in a single backend run don't
# re-hit the geocoder (e.g. when retrying first-session during dev).
_cache: dict[str, tuple[float, float] | None] = {}


def geocode_address(address: str) -> tuple[float, float] | None:
    """Return (lat, lng) for a US address, or None if no match / request
    fails. Results are cached for the lifetime of the process."""
    key = (address or "").strip()
    if not key:
        return None
    if key in _cache:
        return _cache[key]

    try:
        resp = requests.get(
            CENSUS_BASE,
            params={
                "address": key,
                "benchmark": "Public_AR_Current",
                "format": "json",
            },
            headers=HEADERS,
            timeout=10,
        )
        resp.raise_for_status()
        payload = resp.json()
    except Exception as e:  # noqa: BLE001
        print(f"[geocode] request failed for {key!r}: {e}")
        _cache[key] = None
        return None

    matches = (payload.get("result") or {}).get("addressMatches") or []
    if not matches:
        print(f"[geocode] no match for {key!r}")
        _cache[key] = None
        return None

    coords = matches[0].get("coordinates") or {}
    try:
        # Census returns x=longitude, y=latitude.
        lat = float(coords["y"])
        lng = float(coords["x"])
    except (KeyError, ValueError, TypeError) as e:
        print(f"[geocode] malformed response for {key!r}: {e}")
        _cache[key] = None
        return None

    print(f"[geocode] {key!r} -> ({lat}, {lng})")
    _cache[key] = (lat, lng)
    return (lat, lng)
