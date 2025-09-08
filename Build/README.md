# libdav1d XCFramework Build Guide

This README documents a production‑oriented workflow for building a multi‑platform `dav1d.xcframework` (the dav1d AV1 decoder) using Meson/Ninja + Xcode toolchains on macOS.

---

## Prerequisites

- **macOS 15.6+** with **Xcode** (Command Line Tools installed)
- **Homebrew** packages:
  ```bash
  brew install meson ninja nasm
  ```
  > `nasm` is needed for x86_64 simulator builds.

- Network access to clone dav1d (or a local mirror).

---

## Script Overview

The Bash script:
- Pins a dav1d version via `DAV1D_TAG`.
- Builds **static** archives per platform/arch with Meson + clang.
- Uses proper **target triples** and **min deployment** flags for each slice.
- **Coalesces** (via `lipo`) per‑arch archives into **universal** archives where required:
  - macOS → `x86_64 + arm64`
  - iOS Simulator → `x86_64 + arm64`
  - Mac Catalyst → `x86_64 + arm64`
  - tvOS Simulator → `x86_64 + arm64`
  - watchOS Simulator (optional) → `x86_64 + arm64`
- Uses a **single shared headers** directory (`Headers/`) and a **module.modulemap** exporting `dav1d/dav1d.h`.
- Optionally **strips** symbols from archives for size (safe for release) with `STRIP=1`.
- Produces: `output/dav1d.xcframework` suitable for SwiftPM / Xcode integration.

> LTO is disabled (`-Db_lto=false`) to ensure Mach‑O objects (not LLVM bitcode) so that `xcodebuild -create-xcframework` can read architecture info.

---

## Usage

From the [repository root]/Build directory (where your Bash script lives):

```bash
chmod +x build-dav1d-xcframework.sh

# Standard multi-platform build (iOS, iOS Sim, macOS, Catalyst, tvOS; watchOS optional)
./build-dav1d-xcframework.sh
```

### Optional toggles (environment variables)

- **Enable watchOS (device + sim, arm64_32 excluded):**
  ```bash
  ENABLE_WATCHOS=1 ./build-dav1d-xcframework.sh
  ```

- **Strip symbols for smaller archives:**
  ```bash
  STRIP=1 ./build-dav1d-xcframework.sh
  ```

- **Override dav1d tag (pin to a known release):**
  ```bash
  DAV1D_TAG=1.5.1 ./build-dav1d-xcframework.sh
  ```

> You can combine toggles, e.g.:
> ```bash
> ENABLE_WATCHOS=1 STRIP=1 ./build-dav1d-xcframework.sh
> ```

---

## Output Layout

```
Build/
  build-dav1d/
    build-<slice>/src/libdav1d.a          # thin archives per slice
    universal/<family>/libdav1d.a         # universal archives via lipo (per platform family)
    headers/Headers/                        # shared public headers + module.modulemap
output/
  dav1d.xcframework/
    Info.plist
    ios-arm64/
    ios-arm64_x86_64-simulator/
    ios-arm64_x86_64-maccatalyst/
    macos-arm64_x86_64/
    tvos-arm64/
    tvos-arm64_x86_64-simulator/
    (optionally)
    watchos-armv7k/
    watchos-arm64_x86_64-simulator/
```

---

## Sanity Checks

### 1) Verify architectures with `lipo -info`

Check each slice inside the `.xcframework`:

```bash
# iOS device (thin)
lipo -info output/dav1d.xcframework/ios-arm64/libdav1d.a

# iOS simulator (universal)
lipo -info output/dav1d.xcframework/ios-arm64_x86_64-simulator/libdav1d.a

# macOS (universal)
lipo -info output/dav1d.xcframework/macos-arm64_x86_64/libdav1d.a

# Mac Catalyst (universal)
lipo -info output/dav1d.xcframework/ios-arm64_x86_64-maccatalyst/libdav1d.a

# tvOS (device + sim)
lipo -info output/dav1d.xcframework/tvos-arm64/libdav1d.a
lipo -info output/dav1d.xcframework/tvos-arm64_x86_64-simulator/libdav1d.a

# watchOS (optional: armv7k device + sim universal)
lipo -info output/dav1d.xcframework/watchos-armv7k/libdav1d.a
lipo -info output/dav1d.xcframework/watchos-arm64_x86_64-simulator/libdav1d.a
```

**Expected:**  
- device slices: `arm64` (iOS/tvOS), `armv7k` (watchOS)  
- simulator/mac/catalyst universal slices: `x86_64 arm64`

### 2) Validate slice metadata with `plutil`

```bash
plutil -p output/dav1d.xcframework/Info.plist | less
```

Look under the `AvailableLibraries` array. Example for watchOS:
```json
{
  "LibraryIdentifier" => "watchos-arm64_x86_64-simulator",
  "SupportedPlatform" => "watchos",
  "SupportedPlatformVariant" => "simulator",
  "SupportedArchitectures" => ["arm64","x86_64"]
}
{
  "LibraryIdentifier" => "watchos-armv7k",
  "SupportedPlatform" => "watchos",
  "SupportedArchitectures" => ["armv7k"]
}
```

### 3) Confirm public headers are minimal

Only public API headers should be present:
```
Headers/
  dav1d/
    dav1d.h
    ... (other dav1d public headers)
  module.modulemap
```
No `meson.build`, `vcs_version.h.in`, or other build files.

---

## SwiftPM Integration

**Remote binary target** (host `dav1d.xcframework.zip` and compute checksum):

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftDav1d",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
        .macCatalyst(.v14),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        .library(name: "SwiftDav1d", targets: ["SwiftDav1d"])
    ],
    targets: [
        .binaryTarget(
            name: "dav1d",
            url: "https://your.host/path/dav1d.xcframework.zip",
            checksum: "<REPLACE_WITH_SWIFTPM_CHECKSUM>"
        ),
        .target(
            name: "SwiftDav1d",
            dependencies: ["dav1d"]
        )
    ]
)
```

Compute checksum:
```bash
cd output
zip -r dav1d.xcframework.zip dav1d.xcframework
swift package compute-checksum dav1d.xcframework.zip
```

**Local binary target** (no checksum):
```swift
.binaryTarget(name: "dav1d", path: "Sources/dav1d.xcframework")
```

Copy xcframework to the Sources directory (from repository root):
```bash
rsync -a Build/output/dav1d.xcframework Sources/
```
---

## Troubleshooting

- **`Unknown header: 0xb17c0de` during XCFramework creation**  
  You’re passing LLVM bitcode objects (from LTO) instead of Mach‑O. Ensure `-Db_lto=false` in Meson options.

- **Meson warns “Unknown CPU family”**  
  Map Apple‑specific arches to Meson families in your cross file logic:  
  - `arm64, arm64_32 → aarch64`  
  - `armv7k → arm`  
  (We keep the exact `cpu` as the first triple component, only `cpu_family` is normalized.)

- **Catalyst warnings about `-mmacosx-version-min`**  
  Use `-miphoneos-version-min=<iOS>` for macABI while using the macOS SDK.

- **Simulator slice collisions in `-create-xcframework`**  
  Always lipo sim/mac/catalyst pairs into one universal `.a` per platform family, then pass that **single** library to `-create-xcframework`.

- **Headers drift**  
  Use a **single shared Headers dir** for all slices. Keep only the public `dav1d/*.h` files + `module.modulemap`.

- **Size trimming**  
  Enable `STRIP=1` to run `strip -S -x` on thin and universal archives. Expect ~5–15% smaller `.a`s without affecting reliability/perf.

---

## Notes

- Full bitdepth is enabled for maximum visual quality (8/10/16).  
- ASM optimizations are enabled (`-Denable_asm=true`) for NEON/SSSE3, etc.  
- Dead‑strip is enabled via `-ffunction-sections -fdata-sections` + `-Wl,-dead_strip`.  
- If you ever want PGO, dav1d supports it via Meson; it’s advanced and outside this guide.

---

## License / Credits

- dav1d is © VideoLAN and dav1d authors (BSD‑2).  
- This guide just covers the integration/build packaging.
