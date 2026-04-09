// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncHelper",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SyncHelper", targets: ["SyncHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.0.0"),
    ],
    targets: [
        .target(
            name: "SyncHelper",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),
        .testTarget(
            name: "SyncHelperTests",
            dependencies: ["SyncHelper"]
        ),
    ]
)
