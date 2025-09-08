// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "swift-dav1d",
  platforms: [.iOS(.v13), .macOS(.v12), .macCatalyst(.v14), .tvOS(.v13)],
  products: [
    .library(name: "dav1d", targets: ["dav1d"]),
  ],
  targets: [
    // 1) Binary to link
    .binaryTarget(
      name: "dav1dBinary",
      path: "Sources/dav1d.xcframework"
    ),
    // 2) Shim that vends headers/modulemap (no sources)
    .systemLibrary(
      name: "Clibdav1d",
      path: "Sources/Clibdav1d"
    ),
    // 3) Glue target that depends on both
    .target(
      name: "dav1d",
      dependencies: ["dav1dBinary", "Clibdav1d"],
      path: "Sources/dav1d",
      sources: ["shim.swift"] // see below
    ),
  ]
)
