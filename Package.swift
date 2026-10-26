// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShippersShip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ShippersShip", targets: ["ShippersShip"]),
        .executable(name: "ShippersShipWall", targets: ["ShippersShipWall"]),
    ],
    targets: [
        .target(name: "ShipKit"),
        .executableTarget(name: "ShippersShip", dependencies: ["ShipKit"]),
        .executableTarget(name: "ShippersShipWall", dependencies: ["ShipKit"]),
        .testTarget(name: "ShipKitTests", dependencies: ["ShipKit"]),
    ]
)
