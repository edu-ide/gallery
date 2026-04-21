# Gallery iOS Host

Minimal SwiftUI iOS shell for validating the Kotlin Multiplatform shared core.

## Generate the Xcode project

```bash
xcodegen generate --spec iosApp/project.yml --project iosApp
```

## Build shared KMP XCFramework

```bash
./Android/src/gradlew -p Android/src :shared:core:assembleGallerySharedCoreReleaseXCFramework
```

The generated framework is referenced from:

```text
Android/src/shared/core/build/XCFrameworks/release/GallerySharedCore.xcframework
```

The Xcode target also runs this Gradle task as a pre-build step.

## Build iOS simulator app

```bash
xcodebuild -project iosApp/GalleryIOS.xcodeproj \
  -target GalleryIOS \
  -configuration Debug \
  -sdk iphonesimulator \
  build
```

## Build iOS device app without signing

Useful for validating that the Swift host links the `iosArm64` KMP framework:

```bash
xcodebuild -project iosApp/GalleryIOS.xcodeproj \
  -target GalleryIOS \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Install on a physical iPhone

Open `iosApp/GalleryIOS.xcodeproj` in Xcode, select your Apple Development team for the `GalleryIOS` target, then run on the connected iPhone.

Command-line signed install requires an Xcode account/provisioning profile for `com.ugot.galleryios`.


## Runtime adapter seam

`GalleryInferenceRuntime.swift` defines the iOS model runtime seam:

- `GalleryInferenceRuntime` protocol
- `StubGalleryInferenceRuntime` for local shell development
- `LiteRTLMGalleryInferenceRuntime` as the selected iOS runtime path

The iOS app targets LiteRT-LM for Gemma `.litertlm` execution. The Xcode target
runs `scripts/build_litertlm_ios_frameworks.sh` before compilation; that script
builds local LiteRT-LM iOS XCFrameworks from source and places them under
`iosApp/Vendor/LiteRTLM/` (ignored by git because the artifacts are hundreds of
MB). First build can take 30–60 minutes because Bazel compiles LiteRT-LM and its
dependencies.

The Swift runtime uses `GalleryLiteRTLMBridge` when the local XCFrameworks are
linked. Put model files in one of:

- app resources, e.g. `gemma-4-E2B-it.litertlm`
- `Documents/GalleryModels/`
- `Application Support/GalleryModels/`

The default MCP connector is `https://fortune.ugot.uk/mcp`.
