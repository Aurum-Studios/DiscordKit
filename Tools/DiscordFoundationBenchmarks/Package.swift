// swift-tools-version: 6.4
// File: Tools/DiscordFoundationBenchmarks/Package.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import PackageDescription

let settings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency"), .defaultIsolation(nil)]
let package = Package(
    name: "DiscordFoundationBenchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "DiscordKit", path: "../.."), .package(path: "../DiscordBenchmarkSupport"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.1")],
    targets: [
        .executableTarget(name: "DiscordFoundationBenchmarks", dependencies: [
            .product(name: "DiscordBenchmarkSupport", package: "DiscordBenchmarkSupport"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "DiscordBits", package: "DiscordKit"),
            .product(name: "DiscordCore", package: "DiscordKit"),
            .product(name: "DiscordModels", package: "DiscordKit"),
            .product(name: "DiscordDSL", package: "DiscordKit"),
            .product(name: "DiscordCommandDSL", package: "DiscordKit"),
            .product(name: "DiscordCache", package: "DiscordKit"),
            .product(name: "DiscordRPC", package: "DiscordKit"),
        ], swiftSettings: settings),
        .testTarget(name: "DiscordFoundationBenchmarksTests", dependencies: ["DiscordFoundationBenchmarks"], swiftSettings: settings),
    ]
)
