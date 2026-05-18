# OpenFlow Mobile

iOS and Android clients for [OpenFlow](https://github.com/tmart234/OpenFlow) river-flow forecasts.

![App list view](https://raw.githubusercontent.com/tmart234/OpenFlowMobile/dev/assets/SS3.png)

## Repository layout

```
OpenFlowMobile/
├── OpenFlowiOS/              SwiftUI sources (Xcode project at OpenFlowMobile.xcodeproj)
├── OpenFlowAndroid/          Gradle project (package com.tmart234.openflowmobile)
├── assets/                   Marketing/screenshot assets
└── .github/workflows/        CI for both apps
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

Both run on PRs that touch the relevant platform directory, and can be triggered manually via `workflow_dispatch`.

## License

OpenFlow Mobile is licensed under Creative Commons Non-Commercial No-Derivatives. The upstream [OpenFlow](https://github.com/tmart234/OpenFlow) models themselves are MIT-licensed.
