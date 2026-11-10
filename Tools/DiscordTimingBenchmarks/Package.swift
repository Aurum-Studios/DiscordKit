// swift-tools-version: 6.4
// File: Tools/DiscordTimingBenchmarks/Package.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import PackageDescription

let settings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency"), .defaultIsolation(nil)]
let package = Package(
    name: "DiscordTimingBenchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "DiscordKit", path: "../.."), .package(path: "../DiscordBenchmarkSupport")],
    targets: [
        .executableTarget(name: "DiscordTimingBenchmarks", dependencies: [
            .product(name: "DiscordBenchmarkSupport", package: "DiscordBenchmarkSupport"),
            .product(name: "DiscordLogging", package: "DiscordKit"),
            .product(name: "DiscordLogHandlers", package: "DiscordKit"),
            .product(name: "DiscordTransport", package: "DiscordKit"),
            .product(name: "DiscordHTTP", package: "DiscordKit"),
            .product(name: "DiscordCore", package: "DiscordKit"),
        ], swiftSettings: settings),
        .testTarget(name: "DiscordTimingBenchmarksTests", dependencies: ["DiscordTimingBenchmarks"],
            swiftSettings: settings),
    ]
)
