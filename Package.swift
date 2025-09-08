// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "swift-dav1d",
  platforms: [.iOS(.v13), .macOS(.v12), .macCatalyst(.v14), .tvOS(.v13)],
  products: [
    .library(name: "dav1d", targets: ["dav1d"]),
  ],
  dependencies: [
  ],
  targets: [
    .binaryTarget(name: "dav1d", path: "Sources/dav1d.xcframework")
  ]
)
