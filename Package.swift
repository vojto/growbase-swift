// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Growbase",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Growbase", targets: ["Growbase"])],
    targets: [
        .target(name: "Growbase"),
        .testTarget(name: "GrowbaseTests", dependencies: ["Growbase"]),
    ]
)
