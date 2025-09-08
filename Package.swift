// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "swift-dav1d",
  platforms: [.iOS(.v13), .macOS(.v12), .macCatalyst(.v14), .tvOS(.v13)],
  products: [
    .library(name: "dav1d", targets: ["cdav1d"]),
  ],
  targets: [
    // Binary to link
    .binaryTarget(
      name: "dav1dBinary",
      path: "Sources/dav1d.xcframework"
    ),
    // C shim that vends headers + module, and depends on the binary
    .target(
      name: "cdav1d",
      dependencies: ["dav1dBinary"],
      path: "Sources/cdav1d",
      publicHeadersPath: "include",
      cSettings: [
        // If you ever need extra search paths, add them here
        // .headerSearchPath("include")
      ]
    ),
  ]
)
