// swift-tools-version: 6.2

import PackageDescription

// Layers (each talks only to the one below):
//
//   App (SwiftUI)  ->  CargoServices  ->  DeviceKit (protocols, models)
//                                              ^
//                                         ADBKit (transport implementation)
let package = Package(
    name: "DroidCargoKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CargoServices", targets: ["CargoServices"]),
    ],
    targets: [
        .target(name: "DeviceKit"),
        .target(name: "ADBKit", dependencies: ["DeviceKit"]),
        .target(name: "CargoServices", dependencies: ["DeviceKit", "ADBKit"]),
        .testTarget(name: "ADBKitTests", dependencies: ["ADBKit"]),
        .testTarget(name: "CargoServicesTests", dependencies: ["CargoServices", "ADBKit"]),
    ]
)
