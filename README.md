# swift-dav1d
Prebuilt dav1d.xcframework (the dav1d AV1 decoder) for iOS, macOS, Mac Catalyst and tvOS.

## Usage

Use as a dependency in C code with `#include "dav1d/dav1d.h"`, or import as a Swift module with `import Cdav1d`.

## Notes
- Built using Meson/Ninja + Xcode toolchains on macOS
- Full bitdepth is enabled for maximum visual quality (8/10/16).  
- ASM optimizations are enabled (`-Denable_asm=true`) for NEON/SSSE3, etc.
- Dead‑strip and symbol stripping enabled to reduce binary size. 
