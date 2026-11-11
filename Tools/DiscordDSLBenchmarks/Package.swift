// swift-tools-version: 6.4
// File: Tools/DiscordDSLBenchmarks/Package.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import PackageDescription

let settings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency"), .defaultIsolation(nil)]
let package = Package(
    name: "DiscordDSLBenchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "DiscordKit", path: "../.."), .package(path: "../DiscordBenchmarkSupport")],
    targets: [
        .executableTarget(name: "DiscordDSLBenchmarks", dependencies: [
        .product(name: "DiscordBenchmarkSupport", package: "DiscordBenchmarkSupport"),
            .product(name: "DiscordLogging", package: "DiscordKit"),
            .product(name: "DiscordDSL", package: "DiscordKit"),
            .product(name: "DiscordCommandDSL", package: "DiscordKit"),
            .product(name: "DiscordCommands", package: "DiscordKit"),
            .product(name: "DiscordCore", package: "DiscordKit"),
            .product(name: "DiscordModels", package: "DiscordKit"),
            .product(name: "DiscordInteractions", package: "DiscordKit"),
        ], swiftSettings: settings),
        .testTarget(name: "DiscordDSLBenchmarksTests", dependencies: [
            "DiscordDSLBenchmarks",
            .product(name: "DiscordCommandDSL", package: "DiscordKit"),
            .product(name: "DiscordCore", package: "DiscordKit"),
            .product(name: "DiscordDSL", package: "DiscordKit"),
            .product(name: "DiscordInteractions", package: "DiscordKit"),
        ], swiftSettings: settings),
    ]
)
