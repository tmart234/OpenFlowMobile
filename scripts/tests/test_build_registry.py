"""Unit tests for build_registry.py. All HTTP is mocked via `responses`."""
import json

import pytest
import responses

import build_registry as br


@pytest.fixture(autouse=True)
def reset_ghcnd_caches():
    """Module-level caches would leak between tests; clear them."""
    br._GHCND_STATIONS_CACHE = None
    br._GHCND_INVENTORY_CACHE = None
    yield


# --- pure helpers ----------------------------------------------------------

def test_haversine_zero_distance():
    assert br._haversine_km(39.0, -106.0, 39.0, -106.0) == pytest.approx(0.0)


def test_haversine_known_distance():
    # Denver -> Boulder ~= 38 km
    d = br._haversine_km(39.7392, -104.9903, 40.0150, -105.2705)
    assert 35 < d < 45


# --- coordinate resolvers --------------------------------------------------

@responses.activate
def test_resolve_usgs_extracts_lat_lon_and_name():
    rdb = (
        "# comment\n"
        "agency_cd\tsite_no\tstation_nm\tsite_tp_cd\tdec_lat_va\tdec_long_va\n"
        "5s\t15s\t50s\t7s\t16s\t16s\n"
        "USGS\t09163500\tCOLORADO RIVER NEAR CO-UT STATE LINE\tST\t39.1327\t-109.0270\n"
    )
    responses.add(responses.GET, br.USGS_SITE_URL, body=rdb, status=200,
                  content_type="text/plain")

    lat, lon, name = br.resolve_usgs("09163500")

    assert lat == pytest.approx(39.1327)
    assert lon == pytest.approx(-109.0270)
    assert name.startswith("COLORADO RIVER")


@responses.activate
def test_resolve_usgs_returns_none_on_missing_site():
    # USGS returns 200 with no data row if the site is unknown.
    rdb = (
        "agency_cd\tsite_no\tstation_nm\tsite_tp_cd\tdec_lat_va\tdec_long_va\n"
        "5s\t15s\t50s\t7s\t16s\t16s\n"
    )
    responses.add(responses.GET, br.USGS_SITE_URL, body=rdb, status=200)
    assert br.resolve_usgs("99999999") == (None, None, None)


@responses.activate
def test_resolve_dwr_extracts_first_result():
    responses.add(responses.GET, br.DWR_STATIONS_URL, json={
        "ResultList": [{
            "abbrev": "ARKCANCO",
            "stationName": "ARKANSAS RIVER AT CANON CITY",
            "latitude": 38.433624,
            "longitude": -105.257784,
        }],
    })
    lat, lon, name = br.resolve_dwr("ARKCANCO")
    assert lat == pytest.approx(38.433624)
    assert lon == pytest.approx(-105.257784)
    assert name == "ARKANSAS RIVER AT CANON CITY"


@responses.activate
def test_resolve_dwr_handles_empty_results():
    responses.add(responses.GET, br.DWR_STATIONS_URL, json={"ResultList": []})
    assert br.resolve_dwr("BOGUS") == (None, None, None)


# --- HUC8 ------------------------------------------------------------------

@responses.activate
def test_resolve_huc8_zero_pads():
    # WBD sometimes returns an integer rather than zero-padded string.
    responses.add(responses.GET, br.WBD_HUC8_URL, json={
        "features": [{"attributes": {"huc8": 14010005}}],
    })
    assert br.resolve_huc8(39.1, -109.0) == "14010005"


@responses.activate
def test_resolve_huc8_zero_pads_short_codes():
    responses.add(responses.GET, br.WBD_HUC8_URL, json={
        "features": [{"attributes": {"huc8": "1234567"}}],  # 7 chars
    })
    assert br.resolve_huc8(39.1, -109.0) == "01234567"


@responses.activate
def test_resolve_huc8_returns_none_when_no_feature():
    responses.add(responses.GET, br.WBD_HUC8_URL, json={"features": []})
    assert br.resolve_huc8(0, 0) is None


# --- SNOTEL ----------------------------------------------------------------

@responses.activate
def test_resolve_snotel_triplets_dedupes_and_sorts():
    responses.add(responses.GET, br.AWDB_STATIONS_URL, json=[
        {"stationTriplet": "457:CO:SNTL"},
        {"stationTriplet": "457:CO:SNTL"},   # duplicate
        {"stationTriplet": "123:CO:SNOW"},
        {"stationTriplet": None},            # null skipped
        {"otherField": "ignored"},           # missing triplet skipped
    ])
    out = br.resolve_snotel_triplets("14010005")
    assert out == ["123:CO:SNOW", "457:CO:SNTL"]


@responses.activate
def test_resolve_snotel_handles_wrapped_response_shape():
    """Some AWDB deployments wrap the list in {stations: [...]}.}"""
    responses.add(responses.GET, br.AWDB_STATIONS_URL, json={
        "stations": [{"stationTriplet": "999:CO:SNTL"}],
    })
    assert br.resolve_snotel_triplets("14010005") == ["999:CO:SNTL"]


# --- GHCND -----------------------------------------------------------------

# Fixed-width column boundaries per ghcnd-stations.txt format:
#   ID 1-11, LAT 13-20, LON 22-30, NAME 42-71  (1-indexed inclusive)
def _ghcnd_station_line(sid: str, lat: float, lon: float, name: str) -> str:
    # Build a single fixed-width row.
    pad_name = name.ljust(30)[:30]
    return f"{sid:<11} {lat:8.4f} {lon:9.4f}{'':11}{pad_name}{'':50}"


def _ghcnd_inventory_line(sid: str, lat: float, lon: float, element: str, first: int, last: int) -> str:
    return f"{sid:<11} {lat:8.4f} {lon:9.4f} {element:<4} {first:4d} {last:4d}"


@responses.activate
def test_resolve_ghcnd_picks_closest_with_all_elements():
    # Two stations: one closer but missing PRCP, one farther but complete.
    stations_txt = "\n".join([
        _ghcnd_station_line("USC00000001",  39.10, -109.00, "CLOSE NO PRCP"),
        _ghcnd_station_line("USC00000002",  39.50, -109.50, "FAR WITH ALL"),
    ])
    inventory_txt = "\n".join([
        _ghcnd_inventory_line("USC00000001", 39.10, -109.00, "TMIN", 2000, 2026),
        _ghcnd_inventory_line("USC00000001", 39.10, -109.00, "TMAX", 2000, 2026),
        # Missing PRCP for #1.
        _ghcnd_inventory_line("USC00000002", 39.50, -109.50, "TMIN", 2000, 2026),
        _ghcnd_inventory_line("USC00000002", 39.50, -109.50, "TMAX", 2000, 2026),
        _ghcnd_inventory_line("USC00000002", 39.50, -109.50, "PRCP", 2000, 2026),
    ])
    responses.add(responses.GET, br.GHCND_STATIONS_TXT, body=stations_txt)
    responses.add(responses.GET, br.GHCND_INVENTORY_TXT, body=inventory_txt)

    sid, dist = br.resolve_ghcnd(39.0, -109.0, current_year=2026)
    assert sid == "USC00000002"
    assert dist is not None and dist > 0


@responses.activate
def test_resolve_ghcnd_skips_stale_stations():
    # Closest station's last year is too old; should walk to next.
    stations_txt = "\n".join([
        _ghcnd_station_line("USC00000003", 39.10, -109.00, "CLOSE STALE"),
        _ghcnd_station_line("USC00000004", 39.20, -109.10, "FRESH"),
    ])
    inventory_txt = "\n".join([
        _ghcnd_inventory_line("USC00000003", 39.10, -109.00, "TMIN", 1900, 2010),
        _ghcnd_inventory_line("USC00000003", 39.10, -109.00, "TMAX", 1900, 2010),
        _ghcnd_inventory_line("USC00000003", 39.10, -109.00, "PRCP", 1900, 2010),
        _ghcnd_inventory_line("USC00000004", 39.20, -109.10, "TMIN", 2000, 2026),
        _ghcnd_inventory_line("USC00000004", 39.20, -109.10, "TMAX", 2000, 2026),
        _ghcnd_inventory_line("USC00000004", 39.20, -109.10, "PRCP", 2000, 2026),
    ])
    responses.add(responses.GET, br.GHCND_STATIONS_TXT, body=stations_txt)
    responses.add(responses.GET, br.GHCND_INVENTORY_TXT, body=inventory_txt)

    sid, _ = br.resolve_ghcnd(39.0, -109.0, current_year=2026)
    assert sid == "USC00000004"


@responses.activate
def test_resolve_ghcnd_returns_none_when_no_candidate_matches():
    stations_txt = _ghcnd_station_line("USC00000005", 39.0, -109.0, "ONLY")
    inventory_txt = "\n".join([
        _ghcnd_inventory_line("USC00000005", 39.0, -109.0, "TMIN", 2024, 2026),
        # missing TMAX + PRCP
    ])
    responses.add(responses.GET, br.GHCND_STATIONS_TXT, body=stations_txt)
    responses.add(responses.GET, br.GHCND_INVENTORY_TXT, body=inventory_txt)

    sid, dist = br.resolve_ghcnd(39.0, -109.0, current_year=2026)
    assert sid is None
    assert dist is None


# --- end-to-end build_entry ------------------------------------------------

@responses.activate
def test_build_entry_full_resolution(tmp_path):
    rdb = (
        "agency_cd\tsite_no\tstation_nm\tsite_tp_cd\tdec_lat_va\tdec_long_va\n"
        "5s\t15s\t50s\t7s\t16s\t16s\n"
        "USGS\t09163500\tCOLORADO RIVER\tST\t39.13\t-109.02\n"
    )
    responses.add(responses.GET, br.USGS_SITE_URL, body=rdb, status=200)
    responses.add(responses.GET, br.WBD_HUC8_URL, json={
        "features": [{"attributes": {"huc8": "14010005"}}],
    })
    responses.add(responses.GET, br.AWDB_STATIONS_URL, json=[
        {"stationTriplet": "622:CO:SNTL"},
    ])
    stations_txt = _ghcnd_station_line("USC00053307", 39.13, -109.04, "STATION")
    inventory_txt = "\n".join([
        _ghcnd_inventory_line("USC00053307", 39.13, -109.04, "TMIN", 2000, 2026),
        _ghcnd_inventory_line("USC00053307", 39.13, -109.04, "TMAX", 2000, 2026),
        _ghcnd_inventory_line("USC00053307", 39.13, -109.04, "PRCP", 2000, 2026),
    ])
    responses.add(responses.GET, br.GHCND_STATIONS_TXT, body=stations_txt)
    responses.add(responses.GET, br.GHCND_INVENTORY_TXT, body=inventory_txt)

    entry = br.build_entry("USGS:09163500")

    assert entry.agency == "USGS"
    assert entry.site_id == "09163500"
    assert entry.lat == pytest.approx(39.13)
    assert entry.lon == pytest.approx(-109.02)
    assert entry.huc8 == "14010005"
    assert entry.snotel_triplets == ["622:CO:SNTL"]
    assert entry.ghcnd_id == "USC00053307"
    assert entry.notes == []
