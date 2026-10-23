// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OCIBastion",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OCIBastion", targets: ["OCIBastion"])],
    targets: [
        .executableTarget(name: "OCIBastion", path: "Sources/OCIBastion"),
        .testTarget(name: "OCIBastionTests", dependencies: ["OCIBastion"],
                    path: "Tests/OCIBastionTests", exclude: ["Fixtures"])
    ]
)
