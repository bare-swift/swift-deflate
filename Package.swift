// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

import PackageDescription

let package = Package(
    name: "swift-deflate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Deflate", targets: ["Deflate"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
        .package(url: "https://github.com/bare-swift/swift-bytes.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "Deflate",
            dependencies: [
                .product(name: "Bytes", package: "swift-bytes")
            ]
        ),
        .testTarget(
            name: "DeflateTests",
            dependencies: ["Deflate"]
        )
    ]
)
