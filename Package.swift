// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "swift-dav1d",
  platforms: [.iOS(.v13), .macOS(.v12), .macCatalyst(.v14), .tvOS(.v13)],
  products: [
    .library(name: "dav1d", targets: ["Cdav1d"]),
  ],
  targets: [
    .binaryTarget(
      name: "dav1dBinary",
      path: "Sources/dav1d.xcframework"),
    .target(
      name: "Cdav1d",
      dependencies: ["dav1dBinary"],
      publicHeadersPath: "include"
    ),
  ]
)
