#!/usr/bin/env python3
"""
Fetch NASA SMAP daily soil-moisture series per HUC8 in the station registry
and emit one {huc8}.json per basin into .script-output/smap/.

This is the cron-side of the SMAP proxy. Runs in
.github/workflows/smap-update.yml on a daily schedule. The workflow:
  1. checks out tmart234/OpenFlow@dev into upstream-openflow/
  2. pip installs upstream's requirements (earthaccess, h5py, etc.)
  3. runs this script
  4. force-pushes the output to the orphan `smap-data` branch

Apps read https://raw.githubusercontent.com/tmart234/OpenFlowMobile/smap-data/{huc8}.json

Requires the EarthData credentials in env:
  EARTHDATA_USERNAME
  EARTHDATA_PASSWORD
"""
from __future__ import annotations

import json
import os
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pandas as pd

REPO_ROOT = Path(__file__).resolve().parent.parent
REGISTRY_PATH = REPO_ROOT / "data" / "station_registry.json"
OUTPUT_DIR = REPO_ROOT / ".script-output" / "smap"
UPSTREAM_DIR = REPO_ROOT / "upstream-openflow" / "openFlowML"

# Window the apps consume. 60-day encoder + small buffer at both ends so the
# apps can pick any reference date within the recent past without re-fetching.
LOOKBACK_DAYS = 90
END_OFFSET_DAYS = 3  # matches registry.encoder_window_end_offset_days


def _ensure_upstream() -> None:
    if not UPSTREAM_DIR.is_dir():
        sys.exit(
            f"upstream OpenFlow checkout missing at {UPSTREAM_DIR}. "
            "The smap-update workflow handles this with actions/checkout; "
            "to run locally: git clone -b dev https://github.com/tmart234/OpenFlow "
            f"{UPSTREAM_DIR.parent}"
        )
    sys.path.insert(0, str(UPSTREAM_DIR))


def _representative_point(sites: dict, huc8: str) -> tuple[float, float]:
    """Pick any (lat, lon) from the registry that maps to this HUC8."""
    for entry in sites.values():
        if entry.get("huc8") == huc8 and entry.get("lat") is not None:
            return float(entry["lat"]), float(entry["lon"])
    raise RuntimeError(f"no registered site has huc8={huc8}")


def _series_from_df(df: "pd.DataFrame", start: date, end: date) -> list[dict]:
    """
    Reindex the upstream DataFrame to a full daily range; mark each day as
    observed=true iff SMAP returned a real number, else null + observed=false.
    """
    if df.empty:
        idx = pd.date_range(start, end, freq="D", tz="UTC").date
        return [{"date": d.isoformat(), "soil_moisture": None, "observed": False} for d in idx]

    df = df.copy()
    df["Date"] = pd.to_datetime(df["Date"]).dt.date
    df = df.drop_duplicates(subset="Date", keep="last").set_index("Date").sort_index()
    full = pd.date_range(start, end, freq="D").date
    df = df.reindex(full)

    out = []
    for d, value in df["soil_moisture"].items():
        if pd.isna(value):
            out.append({"date": d.isoformat(), "soil_moisture": None, "observed": False})
        else:
            out.append({"date": d.isoformat(), "soil_moisture": round(float(value), 6), "observed": True})
    return out


def main() -> int:
    if not REGISTRY_PATH.is_file():
        sys.exit(f"missing {REGISTRY_PATH} - run scripts/build_registry.py first")
    registry = json.loads(REGISTRY_PATH.read_text())
    sites: dict = registry.get("sites", {})

    huc8s = sorted({entry["huc8"] for entry in sites.values() if entry.get("huc8")})
    if not huc8s:
        sys.exit("registry has no HUC8s")

    _ensure_upstream()
    from data import nasa_moisture  # noqa: E402

    today = datetime.now(timezone.utc).date()
    end = today - timedelta(days=END_OFFSET_DAYS)
    start = end - timedelta(days=LOOKBACK_DAYS)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest_entries = []

    for huc8 in huc8s:
        try:
            lat, lon = _representative_point(sites, huc8)
        except RuntimeError as e:
            print(f"skip {huc8}: {e}", file=sys.stderr)
            continue

        print(f"fetching SMAP for huc8={huc8} ({start}..{end})", file=sys.stderr)
        try:
            df = nasa_moisture.main(lat, lon, start, end)
        except Exception as e:
            print(f"  ! upstream nasa_moisture failed for {huc8}: {e}", file=sys.stderr)
            df = pd.DataFrame(columns=["Date", "soil_moisture"])

        series = _series_from_df(df, start, end)
        observed = sum(1 for r in series if r["observed"])

        payload = {
            "schema_version": 1,
            "huc8": huc8,
            "lat": lat,
            "lon": lon,
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "observed_days": observed,
            "total_days": len(series),
            "series": series,
        }
        (OUTPUT_DIR / f"{huc8}.json").write_text(json.dumps(payload, indent=2) + "\n")
        print(f"  wrote {huc8}.json ({observed}/{len(series)} days observed)", file=sys.stderr)
        manifest_entries.append({
            "huc8": huc8, "observed_days": observed, "total_days": len(series),
        })

    manifest = {
        "schema_version": 1,
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "start_date": start.isoformat(),
        "end_date": end.isoformat(),
        "basins": manifest_entries,
    }
    (OUTPUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote manifest.json with {len(manifest_entries)} basins", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
