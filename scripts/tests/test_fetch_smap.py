"""Unit tests for fetch_smap.py. Mocks the upstream SMAP function so tests
don't need an upstream OpenFlow checkout or EarthData credentials."""
from datetime import date

import pandas as pd
import pytest

import fetch_smap as fs


# --- representative point --------------------------------------------------

def test_representative_point_picks_matching_huc():
    sites = {
        "USGS:1": {"lat": 39.0, "lon": -109.0, "huc8": "14010005"},
        "USGS:2": {"lat": 40.0, "lon": -107.0, "huc8": "14010001"},
        "USGS:3": {"lat": 41.0, "lon": -108.0, "huc8": "14010005"},
    }
    lat, lon = fs._representative_point(sites, "14010005")
    # Either USGS:1 or USGS:3 (dict iteration order is insertion-ordered in
    # CPython 3.7+, so it'll be USGS:1).
    assert (lat, lon) == (39.0, -109.0)


def test_representative_point_raises_when_no_match():
    sites = {"USGS:1": {"lat": 39.0, "lon": -109.0, "huc8": "14010005"}}
    with pytest.raises(RuntimeError, match="no registered site"):
        fs._representative_point(sites, "99999999")


def test_representative_point_skips_sites_with_no_coords():
    sites = {
        "USGS:1": {"lat": None, "lon": None, "huc8": "14010005"},
        "USGS:2": {"lat": 40.0, "lon": -107.0, "huc8": "14010005"},
    }
    assert fs._representative_point(sites, "14010005") == (40.0, -107.0)


# --- series alignment ------------------------------------------------------

def test_series_from_df_full_range_all_observed():
    df = pd.DataFrame({
        "Date": [date(2026, 5, 1), date(2026, 5, 2), date(2026, 5, 3)],
        "soil_moisture": [0.21, 0.22, 0.23],
    })
    out = fs._series_from_df(df, date(2026, 5, 1), date(2026, 5, 3))
    assert [r["date"] for r in out] == ["2026-05-01", "2026-05-02", "2026-05-03"]
    assert all(r["observed"] for r in out)
    assert [r["soil_moisture"] for r in out] == [0.21, 0.22, 0.23]


def test_series_from_df_marks_gaps_as_unobserved():
    df = pd.DataFrame({
        "Date": [date(2026, 5, 1), date(2026, 5, 3)],
        "soil_moisture": [0.21, 0.23],
    })
    out = fs._series_from_df(df, date(2026, 5, 1), date(2026, 5, 3))
    assert len(out) == 3
    assert out[0] == {"date": "2026-05-01", "soil_moisture": 0.21, "observed": True}
    assert out[1] == {"date": "2026-05-02", "soil_moisture": None, "observed": False}
    assert out[2] == {"date": "2026-05-03", "soil_moisture": 0.23, "observed": True}


def test_series_from_df_handles_empty_dataframe():
    out = fs._series_from_df(
        pd.DataFrame(columns=["Date", "soil_moisture"]),
        date(2026, 5, 1), date(2026, 5, 3),
    )
    assert len(out) == 3
    assert all(not r["observed"] and r["soil_moisture"] is None for r in out)


def test_series_from_df_dedupes_same_day_keeping_last():
    df = pd.DataFrame({
        "Date": [date(2026, 5, 1), date(2026, 5, 1)],  # duplicate
        "soil_moisture": [0.10, 0.42],
    })
    out = fs._series_from_df(df, date(2026, 5, 1), date(2026, 5, 1))
    assert out == [{"date": "2026-05-01", "soil_moisture": 0.42, "observed": True}]


def test_series_from_df_treats_nan_as_unobserved():
    df = pd.DataFrame({
        "Date": [date(2026, 5, 1), date(2026, 5, 2)],
        "soil_moisture": [0.21, float("nan")],
    })
    out = fs._series_from_df(df, date(2026, 5, 1), date(2026, 5, 2))
    assert out[0]["observed"] is True
    assert out[1]["observed"] is False
    assert out[1]["soil_moisture"] is None


# --- build_payload integration --------------------------------------------

def test_build_payload_includes_metadata_and_counts():
    def fake_fetch(lat, lon, start, end):
        return pd.DataFrame({
            "Date": [date(2026, 5, 1), date(2026, 5, 2)],
            "soil_moisture": [0.21, 0.22],
        })

    payload = fs.build_payload(
        "14010005", 39.13, -109.02,
        date(2026, 5, 1), date(2026, 5, 3),
        fake_fetch,
    )
    assert payload["huc8"] == "14010005"
    assert payload["lat"] == 39.13
    assert payload["lon"] == -109.02
    assert payload["start_date"] == "2026-05-01"
    assert payload["end_date"] == "2026-05-03"
    assert payload["total_days"] == 3
    assert payload["observed_days"] == 2
    assert len(payload["series"]) == 3


def test_build_payload_swallows_upstream_failure():
    def boom(lat, lon, start, end):
        raise RuntimeError("EarthData login failed")

    payload = fs.build_payload(
        "14010005", 39.13, -109.02,
        date(2026, 5, 1), date(2026, 5, 2),
        boom,
    )
    # Failure -> empty DataFrame -> all days unobserved, but still a valid payload.
    assert payload["observed_days"] == 0
    assert payload["total_days"] == 2
    assert all(not r["observed"] for r in payload["series"])
