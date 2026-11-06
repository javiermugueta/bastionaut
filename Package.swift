// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OCIBastion",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OCIBastion", targets: ["OCIBastion"])],
    dependencies: [
        // Terminal integrado para «Abrir SSH» (licencia MIT).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.0")
    ],
    targets: [
        .executableTarget(name: "OCIBastion", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
                          path: "Sources/OCIBastion"),
        .testTarget(name: "OCIBastionTests", dependencies: ["OCIBastion"],
                    path: "Tests/OCIBastionTests", exclude: ["Fixtures"])
    ]
)
