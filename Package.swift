// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShippersShip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ShippersShip", targets: ["ShippersShip"]),
    ],
    targets: [
        .target(name: "ShipKit"),
        .executableTarget(name: "ShippersShip", dependencies: ["ShipKit"]),
        .testTarget(name: "ShipKitTests", dependencies: ["ShipKit"]),
    ]
)
