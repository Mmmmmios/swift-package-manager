// swift-tools-version:5.8

import PackageDescription

var swiftSettings: [SwiftSetting] = []

let package = Package(
    name: "WithErrors",
    targets: [
        .target(
            name: "CannotFindSettings",
            swiftSettings: swiftSettings
        ),
        .target(name: "A"),
        .target(name: "B"),
    ]
)

package.targets.append(
    .target(
        name: "CannotFindTarget",
        swiftSettings: swiftSettings
    ),
)
