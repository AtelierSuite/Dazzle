// swift-tools-version:6.0
//
// The Dazzle engine: the presentation model and reading and writing PowerPoint
// and Keynote files, with slide drawing on Apple platforms. Shared by the Apple
// apps (whose Xcode project compiles this folder directly) and the web app
// (Web/engine, which depends on this package and builds it for WebAssembly).

import PackageDescription

let package = Package(
    name: "DazzleEngine",
    products: [
        .library(name: "DazzleEngine", targets: ["DazzleEngine"]),
    ],
    targets: [
        .target(
            name: "DazzleEngine",
            path: "DazzleEngine",
            // Compiled into the Apple framework by Xcode; the web app loads
            // the same strings as JSON instead.
            exclude: ["Localizable.xcstrings"]
        ),
    ]
)
