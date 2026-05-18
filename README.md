# OpenFlow Mobile

iOS and Android clients for [OpenFlow](https://github.com/tmart234/OpenFlow) river-flow forecasts.

![App list view](https://raw.githubusercontent.com/tmart234/OpenFlowMobile/dev/assets/SS3.png)

## Repository layout

```
OpenFlowMobile/
├── OpenFlowiOS/              SwiftUI sources (Xcode project at OpenFlowMobile.xcodeproj)
├── OpenFlowAndroid/          Gradle project (package com.tmart234.openflowmobile)
├── data/                     Build-time data bundled into both apps (station_registry.json)
├── scripts/                  Backend tooling: registry builder + SMAP cron
├── assets/                   Marketing/screenshot assets
└── .github/workflows/        CI for both apps + registry/SMAP automation
```

## Status

This repo is mid-refactor. Track the work in branch [`claude/review-mobile-app-refactor-b0nIk`](../../tree/claude/review-mobile-app-refactor-b0nIk).

- **iOS**: builds. ML stack (`MLContract`, `ModelBundle`, `ModelManager`, `FeaturePipeline`) wired to upstream's published contract. The runtime feature pipeline that assembles encoder/decoder windows from live data is Phase 2 — until then the forecast UI shows "feature pipeline not implemented" rather than fake numbers.
- **Android**: ML stack in place (`com.tmart234.openflowmobile.ml.*`) mirroring iOS. TFLite + kotlinx.serialization + OkHttp dependencies added. No real screens yet — Phase 4 builds the UI.
- **ML pipeline**: [upstream OpenFlow](https://github.com/tmart234/OpenFlow) publishes a `model-YYYY.MM.DD` GitHub release with `lstm_model.mlpackage.zip`, `lstm_model.tflite`, and four companion JSONs. The first release lands when upstream's `dev` merges to `main`. The mobile `ModelManager` downloads + sha256-verifies the latest release, caches it, swaps in a bundled fallback when offline. Contract: [docs/INFERENCE.md](https://github.com/tmart234/OpenFlow/blob/dev/docs/INFERENCE.md).

## Building

### iOS

Requires Xcode 15.4+ on macOS 14+.

```bash
open OpenFlowMobile.xcodeproj
# or
xcodebuild -project OpenFlowMobile.xcodeproj \
           -scheme OpenFlowMobile \
           -destination 'generic/platform=iOS Simulator' \
           build
```

### Android

Requires JDK 17.

```bash
cd OpenFlowAndroid
./gradlew assembleDebug
./gradlew testDebugUnitTest
./gradlew lintDebug
```

## CI

- `ios-ci.yml` — builds the iOS app on `macos-14` for the iOS Simulator (no code signing).
- `android-ci.yml` — assembles debug, runs lint, runs unit tests on `ubuntu-latest`.
- `registry-update.yml` — manual + quarterly. Re-resolves every supported site via the upstream public APIs (USGS NWIS, WBD MapServer, NRCS AWDB, NCEI GHCND) and opens a PR with the regenerated `data/station_registry.json` if anything changed.
- `smap-update.yml` — daily at 08:00 UTC. Checks out upstream OpenFlow, calls its NASA SMAP polygon-extractor for every HUC8 in the registry, force-pushes a `{huc8}.json` per basin to the orphan `smap-data` branch. Requires repo secrets `EARTHDATA_USERNAME` + `EARTHDATA_PASSWORD`.

The first three run on PRs / pushes that touch the relevant directory; all four can be triggered manually via `workflow_dispatch`.

## Data architecture

The apps run inference fully on-device. Two static-data feeds live in this repo:

- **`data/station_registry.json`** (committed to `main`, bundled into the apps at build time) — per-site `{lat, lon, huc8, snotel_triplets, ghcnd_id}`. Sourced from anonymous USGS/WBD/AWDB/NCEI endpoints. Apps look up site metadata instantly from the bundle; no network required.
- **`smap-data/{huc8}.json`** on the orphan `smap-data` branch (refreshed nightly) — daily soil-moisture series per HUC8 for the last ~90 days. SMAP is the only data source the apps can't hit directly because NASA EarthData credentials can't ship in a client. Apps fetch via `https://raw.githubusercontent.com/tmart234/OpenFlowMobile/smap-data/{huc8}.json`.

Every other feature (USGS/CODWR flow, NCEI GHCND historical temp+precip, NRCS AWDB SWE, USDM drought, USBR RISE reservoirs, Open-Meteo 14-day forecast) is fetched directly by the apps from public APIs. See `scripts/build_registry.py` and `scripts/fetch_smap.py` for the implementations.

## License

OpenFlow Mobile is licensed under Creative Commons Non-Commercial No-Derivatives. The upstream [OpenFlow](https://github.com/tmart234/OpenFlow) models themselves are MIT-licensed.
