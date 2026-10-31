// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ActivityImportCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ActivityImportCore", targets: ["ActivityImportCore"])],
    targets: [
        .target(name: "ActivityImportCore"),
        .testTarget(name: "ActivityImportCoreTests", dependencies: ["ActivityImportCore"],
                    path: "Tests", resources: [.copy("Fixtures")])
    ]
)
