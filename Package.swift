// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "diskreport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskReportCore", targets: ["DiskReportCore"]),
        .library(name: "DiskReportUI", targets: ["DiskReportUI"]),
        .executable(name: "diskreport-scan", targets: ["diskreport-scan"]),
        .executable(name: "DiskReport", targets: ["DiskReport"]),
    ],
    targets: [
        .target(name: "DiskReportCore"),
        .target(name: "DiskReportUI", dependencies: ["DiskReportCore"]),
        .executableTarget(name: "diskreport-scan", dependencies: ["DiskReportCore"]),
        .executableTarget(name: "DiskReport", dependencies: ["DiskReportCore", "DiskReportUI"]),
        .testTarget(name: "DiskReportCoreTests", dependencies: ["DiskReportCore"]),
        .testTarget(name: "DiskReportUITests", dependencies: ["DiskReportUI"]),
    ]
)
