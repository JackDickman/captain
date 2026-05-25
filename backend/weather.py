"""
National Weather Service forecast fetcher.

Free, no API key. Two-step API:
  1. GET /points/{lat},{lng}        → gridId + gridX + gridY for the location
  2. GET /gridpoints/{...}/forecast → 7-day periods

Cached per lat/lng for an hour. Returns a short prose summary suitable for
inclusion in the LLM's system prompt.
"""

from __future__ import annotations

import time

import requests

NWS_BASE = "https://api.weather.gov"
# NWS requires a User-Agent; format per docs: app + contact.
HEADERS = {
    "User-Agent": "captain-app/0.1 (jack@example.com)",
    "Accept": "application/geo+json",
}
CACHE_TTL_SECONDS = 60 * 60

# In-memory cache: { (lat,lng) -> (timestamp, summary) }
_cache: dict[tuple[float, float], tuple[float, str]] = {}
# Same cache shape but values are structured period dicts (for the iOS widget)
_structured_cache: dict[tuple[float, float], tuple[float, list[dict]]] = {}


def _round(coord: float) -> float:
    # NWS responds with normalized coords; small jitter on the input shouldn't
    # bust our cache key.
    return round(coord, 3)


def _format_period(period: dict) -> str:
    name = period.get("name", "")
    temp = period.get("temperature")
    unit = period.get("temperatureUnit", "F")
    short = period.get("shortForecast", "")
    if temp is None:
        return f"{name}: {short}"
    return f"{name}: {temp}°{unit}, {short}"


def get_forecast_structured(lat: float, lng: float,
                            max_periods: int = 4) -> list[dict]:
    """Return structured forecast periods for UI rendering. Each is
    {name, temperature, unit, short, isDaytime}. Returns [] on failure.
    Cached separately from the prose summary (same TTL)."""
    key = (_round(lat), _round(lng))
    now = time.time()
    cached = _structured_cache.get(key)
    if cached and now - cached[0] < CACHE_TTL_SECONDS:
        return cached[1]

    try:
        points = requests.get(
            f"{NWS_BASE}/points/{key[0]},{key[1]}",
            headers=HEADERS, timeout=10,
        )
        points.raise_for_status()
        forecast_url = points.json()["properties"]["forecast"]
        fc = requests.get(forecast_url, headers=HEADERS, timeout=10)
        fc.raise_for_status()
        periods = fc.json()["properties"]["periods"][:max_periods]
        result = [
            {
                "name": p.get("name", ""),
                "temperature": p.get("temperature"),
                "unit": p.get("temperatureUnit", "F"),
                "short": p.get("shortForecast", ""),
                "isDaytime": p.get("isDaytime", True),
            }
            for p in periods
        ]
    except Exception as e:  # noqa: BLE001
        print(f"[weather] structured error: {e}")
        result = []

    _structured_cache[key] = (now, result)
    return result


def get_forecast_summary(lat: float, lng: float, max_periods: int = 4) -> str:
    """Return a 2-3 sentence forecast summary, or '' on failure.

    Failures are non-fatal: chat still works without weather, just slightly
    less context-aware.
    """
    key = (_round(lat), _round(lng))
    now = time.time()
    cached = _cache.get(key)
    if cached and now - cached[0] < CACHE_TTL_SECONDS:
        return cached[1]

    try:
        points = requests.get(
            f"{NWS_BASE}/points/{key[0]},{key[1]}",
            headers=HEADERS, timeout=10,
        )
        points.raise_for_status()
        forecast_url = points.json()["properties"]["forecast"]
        fc = requests.get(forecast_url, headers=HEADERS, timeout=10)
        fc.raise_for_status()
        periods = fc.json()["properties"]["periods"][:max_periods]
        summary = " · ".join(_format_period(p) for p in periods)
    except Exception as e:  # noqa: BLE001
        print(f"[weather] error: {e}")
        summary = ""

    _cache[key] = (now, summary)
    return summary
