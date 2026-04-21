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
