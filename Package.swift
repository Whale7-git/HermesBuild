// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesShell",
    platforms: [.iOS(.v18)],
    products: [.library(name: "HermesShell", targets: ["HermesShell"])],
    dependencies: [
        .package(path: "Vendor/Textual"),
        // F-64 supply-chain audit. The vendored Textual manifest pulls
        // swiftui-math in with a bare `from: "0.1.0"`, which has no upper
        // bound, so any future 0.x minor could reach a release build without
        // review. SwiftPM intersects the requirements declared for the same
        // package identity, so declaring the bound here constrains the whole
        // graph without forking the vendored manifest. 0.1.0 is the revision
        // already locked in Package.resolved, so the resolved version does not
        // move; the bound only blocks drift into 0.2.x.
        .package(url: "https://github.com/gonzalezreal/swiftui-math", .upToNextMinor(from: "0.1.0")),
    ],
    targets: [
        .target(
            name: "HermesShell",
            dependencies:[
                .product(name:"Textual",package:"textual")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
