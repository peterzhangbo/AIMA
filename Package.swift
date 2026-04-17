// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SummaryMeeting",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SummaryMeetingApp", targets: ["SummaryMeetingApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "SummaryMeetingApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/SummaryMeetingApp"
        ),
        .testTarget(
            name: "SummaryMeetingAppTests",
            dependencies: ["SummaryMeetingApp"],
            path: "Tests/SummaryMeetingAppTests"
        )
    ]
)
