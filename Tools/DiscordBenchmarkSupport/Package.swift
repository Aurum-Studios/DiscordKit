// swift-tools-version: 6.4
// File: Tools/DiscordBenchmarkSupport/Package.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
    .defaultIsolation(nil),
]

let package = Package(
    name: "DiscordBenchmarkSupport",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiscordBenchmarkSupport", targets: ["DiscordBenchmarkSupport"]),
        .executable(name: "DiscordBenchmarkReports", targets: ["DiscordBenchmarkReports"]),
    ],
    targets: [
        .target(name: "DiscordBenchmarkSupport", swiftSettings: concurrencySettings),
        .executableTarget(name: "DiscordBenchmarkReports", dependencies: ["DiscordBenchmarkSupport"],
            swiftSettings: concurrencySettings),
        .testTarget(
            name: "DiscordBenchmarkSupportTests",
            dependencies: ["DiscordBenchmarkSupport"],
            swiftSettings: concurrencySettings
        ),
    ]
)
