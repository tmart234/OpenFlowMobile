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

- **iOS**: builds, but architecture and ML inference need rework. The ML model bundled at runtime is fed placeholder inputs — the forecast graph is currently not meaningful.
- **Android**: scaffolded only. Three stub fragments with no networking, persistence, or ML. Needs a from-scratch build to reach iOS parity.
- **ML pipeline**: the [upstream OpenFlow](https://github.com/tmart234/OpenFlow) repo is rewriting how models are published. Mobile will consume per-platform model artifacts (Core ML for iOS, TFLite/ONNX for Android) once upstream is ready.

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
