#!/usr/bin/env python3
"""
Build data/station_registry.json for the OpenFlow mobile apps.

For each supported site, resolves:
  - lat / lon (USGS NWIS or CODWR surfacewaterstations)
  - HUC8 (USGS WBD MapServer)
  - SNOTEL station triplets in that HUC8 (NRCS AWDB)
  - Closest GHCND station with recent TMIN/TMAX coverage (NCEI)

The registry is the source of truth for both apps (bundled at build time)
AND for the SMAP cron job (which iterates the unique HUC8s to publish
soil-moisture timeseries to the smap-data branch).

Has no dependency on upstream OpenFlow - every resolver is an anonymous
HTTP call we inline here. Stdlib + requests only.

Re-run via .github/workflows/registry-update.yml or:
    pip install requests
    python scripts/build_registry.py

Exit code 0 on success even if some sites partially resolve; failures are
logged. Exit code 1 only if the registry would be empty.
"""
from __future__ import annotations

import csv
import io
import json
import math
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, Optional

import requests

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = REPO_ROOT / "data" / "station_registry.json"

# Mirrors upstream .github/site_ids.txt. Keep in sync when upstream adds sites.
SUPPORTED_SITES: list[str] = [
    "USGS:09163500",
    "USGS:09114500",
    "USGS:09070500",
    "DWR:ARKCANCO",
]

UA = "OpenFlowMobile-registry-builder/1 (+https://github.com/tmart234/OpenFlowMobile)"
SESSION = requests.Session()
SESSION.headers.update({"User-Agent": UA})

USGS_SITE_URL = "https://waterservices.usgs.gov/nwis/site/"
DWR_STATIONS_URL = "https://dwr.state.co.us/Rest/GET/api/v2/surfacewater/surfacewaterstations/"
WBD_HUC8_URL = "https://hydro.nationalmap.gov/arcgis/rest/services/wbd/MapServer/4/query"
AWDB_STATIONS_URL = "https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1/stations"
GHCND_STATIONS_TXT = "https://www.ncei.noaa.gov/pub/data/ghcn/daily/ghcnd-stations.txt"
GHCND_INVENTORY_TXT = "https://www.ncei.noaa.gov/pub/data/ghcn/daily/ghcnd-inventory.txt"


@dataclass
class SiteEntry:
    agency: str
    site_id: str
    name: Optional[str] = None
    lat: Optional[float] = None
    lon: Optional[float] = None
    huc8: Optional[str] = None
    snotel_triplets: list[str] = field(default_factory=list)
    ghcnd_id: Optional[str] = None
    ghcnd_distance_km: Optional[float] = None
    notes: list[str] = field(default_factory=list)


def http_get(url: str, *, params: Optional[dict] = None, retries: int = 3, timeout: int = 30) -> requests.Response:
    """GET with retry on 5xx / connection errors."""
    last_exc: Optional[Exception] = None
    for attempt in range(1, retries + 1):
        try:
            resp = SESSION.get(url, params=params, timeout=timeout)
            if resp.status_code < 500:
                return resp
            last_exc = RuntimeError(f"HTTP {resp.status_code}")
        except (requests.ConnectionError, requests.Timeout) as e:
            last_exc = e
        time.sleep(2 ** attempt)
    raise RuntimeError(f"GET {url} failed after {retries} attempts: {last_exc}")


# --- coordinate resolvers ---------------------------------------------------

def resolve_usgs(site_id: str) -> tuple[Optional[float], Optional[float], Optional[str]]:
    resp = http_get(USGS_SITE_URL, params={"format": "rdb", "sites": site_id})
    if resp.status_code != 200:
        return None, None, None
    for line in resp.text.splitlines():
        if line.startswith("#") or line.startswith("agency_cd") or line.startswith("5s"):
            continue
        parts = line.split("\t")
        if len(parts) >= 6 and parts[1] == site_id:
            try:
                return float(parts[4]), float(parts[5]), parts[2]
            except ValueError:
                continue
    return None, None, None


def resolve_dwr(abbrev: str) -> tuple[Optional[float], Optional[float], Optional[str]]:
    resp = http_get(DWR_STATIONS_URL, params={
        "format": "json",
        "abbrev": abbrev,
        "fields": "abbrev,stationName,latitude,longitude",
    })
    if resp.status_code != 200:
        return None, None, None
    body = resp.json()
    rows = body.get("ResultList") or []
    if not rows:
        return None, None, None
    row = rows[0]
    return row.get("latitude"), row.get("longitude"), row.get("stationName")


# --- HUC8 ------------------------------------------------------------------

def resolve_huc8(lat: float, lon: float) -> Optional[str]:
    resp = http_get(WBD_HUC8_URL, params={
        "f": "json",
        "geometry": f"{lon},{lat}",
        "geometryType": "esriGeometryPoint",
        "inSR": "4326",
        "returnGeometry": "false",
        "outFields": "huc8",
        "spatialRel": "esriSpatialRelIntersects",
    })
    if resp.status_code != 200:
        return None
    features = resp.json().get("features") or []
    if not features:
        return None
    return str(features[0].get("attributes", {}).get("huc8") or "").zfill(8) or None


# --- SNOTEL ----------------------------------------------------------------

def resolve_snotel_triplets(huc8: str) -> list[str]:
    resp = http_get(AWDB_STATIONS_URL, params={
        "hucs": huc8,
        "elements": "WTEQ",
        "activeOnly": "true",
    })
    if resp.status_code != 200:
        return []
    body = resp.json()
    # API returns a list of stations; each has stationTriplet (e.g. "457:CO:SNTL")
    items = body if isinstance(body, list) else body.get("stations", [])
    triplets = []
    for item in items:
        t = item.get("stationTriplet")
        if t:
            triplets.append(t)
    return sorted(set(triplets))


# --- GHCND -----------------------------------------------------------------

_GHCND_STATIONS_CACHE: Optional[list[tuple[str, float, float, str]]] = None
_GHCND_INVENTORY_CACHE: Optional[dict[str, dict]] = None


def _load_ghcnd_stations() -> list[tuple[str, float, float, str]]:
    """Returns [(id, lat, lon, name), ...]. Filters to US stations only."""
    global _GHCND_STATIONS_CACHE
    if _GHCND_STATIONS_CACHE is not None:
        return _GHCND_STATIONS_CACHE
    resp = http_get(GHCND_STATIONS_TXT, timeout=120)
    out: list[tuple[str, float, float, str]] = []
    # Fixed-width columns per https://docs.opendata.aws/noaa-ghcn-pds/readme.html
    # ID 1-11, LAT 13-20, LON 22-30, NAME 42-71
    for raw in resp.text.splitlines():
        if len(raw) < 71:
            continue
        sid = raw[0:11].strip()
        if not sid.startswith("US"):
            continue
        try:
            lat = float(raw[12:20])
            lon = float(raw[21:30])
        except ValueError:
            continue
        name = raw[41:71].strip()
        out.append((sid, lat, lon, name))
    _GHCND_STATIONS_CACHE = out
    return out


def _load_ghcnd_inventory() -> dict[str, dict]:
    """Per-station element inventory: {station_id: {element: (first_year, last_year)}}."""
    global _GHCND_INVENTORY_CACHE
    if _GHCND_INVENTORY_CACHE is not None:
        return _GHCND_INVENTORY_CACHE
    resp = http_get(GHCND_INVENTORY_TXT, timeout=120)
    out: dict[str, dict] = {}
    # Cols: ID 1-11, LAT 13-20, LON 22-30, ELEMENT 32-35, FIRSTYEAR 37-40, LASTYEAR 42-45
    for raw in resp.text.splitlines():
        if len(raw) < 45:
            continue
        sid = raw[0:11].strip()
        if not sid.startswith("US"):
            continue
        element = raw[31:35].strip()
        try:
            first = int(raw[36:40])
            last = int(raw[41:45])
        except ValueError:
            continue
        out.setdefault(sid, {})[element] = (first, last)
    _GHCND_INVENTORY_CACHE = out
    return out


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def resolve_ghcnd(lat: float, lon: float, *, current_year: int) -> tuple[Optional[str], Optional[float]]:
    """Closest US GHCND station with recent TMIN+TMAX+PRCP coverage."""
    stations = _load_ghcnd_stations()
    inventory = _load_ghcnd_inventory()
    # Sort candidates by distance, return first with all 3 elements active in last 2 years.
    candidates = sorted(
        ((s, _haversine_km(lat, lon, s[1], s[2])) for s in stations if s[0] in inventory),
        key=lambda x: x[1],
    )
    for (sid, slat, slon, _name), dist_km in candidates[:200]:
        elems = inventory.get(sid, {})
        if all(e in elems and elems[e][1] >= current_year - 1 for e in ("TMIN", "TMAX", "PRCP")):
            return sid, round(dist_km, 2)
    return None, None


# --- main ------------------------------------------------------------------

def build_entry(full_id: str) -> SiteEntry:
    agency, sid = full_id.split(":", 1)
    entry = SiteEntry(agency=agency, site_id=sid)

    try:
        if agency == "USGS":
            entry.lat, entry.lon, entry.name = resolve_usgs(sid)
        elif agency == "DWR":
            entry.lat, entry.lon, entry.name = resolve_dwr(sid)
        else:
            entry.notes.append(f"unknown agency {agency!r}; skipping")
            return entry
    except Exception as e:
        entry.notes.append(f"coord lookup failed: {e}")

    if entry.lat is None or entry.lon is None:
        entry.notes.append("could not resolve coordinates")
        return entry

    try:
        entry.huc8 = resolve_huc8(entry.lat, entry.lon)
    except Exception as e:
        entry.notes.append(f"huc8 lookup failed: {e}")

    if entry.huc8:
        try:
            entry.snotel_triplets = resolve_snotel_triplets(entry.huc8)
        except Exception as e:
            entry.notes.append(f"snotel lookup failed: {e}")

    try:
        entry.ghcnd_id, entry.ghcnd_distance_km = resolve_ghcnd(
            entry.lat, entry.lon, current_year=datetime.now(timezone.utc).year,
        )
    except Exception as e:
        entry.notes.append(f"ghcnd lookup failed: {e}")

    return entry


def main(sites: Iterable[str] = SUPPORTED_SITES) -> int:
    entries: dict[str, dict] = {}
    failed = 0
    for full_id in sites:
        print(f"resolving {full_id}...", file=sys.stderr)
        entry = build_entry(full_id)
        if entry.lat is None:
            failed += 1
        entries[full_id] = asdict(entry)

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": 1,
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "encoder_window_end_offset_days": 3,
        "sites": entries,
    }
    OUTPUT_PATH.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"wrote {OUTPUT_PATH} ({len(entries)} entries, {failed} failed coord lookups)", file=sys.stderr)

    if failed == len(entries):
        print("all sites failed - not committing an empty registry", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
