// swift-tools-version: 6.4
// File: Tools/DiscordMediaBenchmarks/Package.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import PackageDescription

let settings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency"), .defaultIsolation(nil)]
let package = Package(
    name: "DiscordMediaBenchmarks", platforms: [.macOS(.v13)],
    dependencies: [.package(name: "DiscordKit", path: "../.."), .package(path: "../DiscordBenchmarkSupport"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.1")],
    targets: [
        .executableTarget(name: "DiscordMediaBenchmarks", dependencies: [
            .product(name: "DiscordBenchmarkSupport", package: "DiscordBenchmarkSupport"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "DiscordMedia", package: "DiscordKit"),
            .product(name: "DiscordVoiceCodecs", package: "DiscordKit"),
            .product(name: "DiscordVoice", package: "DiscordKit"),
            .product(name: "DiscordVoiceCrypto", package: "DiscordKit"),
            .product(name: "DiscordDAVE", package: "DiscordKit"),
            .product(name: "DiscordMLS", package: "DiscordKit"),
            .product(name: "DiscordCore", package: "DiscordKit"),
            .product(name: "DiscordModels", package: "DiscordKit"),
            .product(name: "DiscordLogging", package: "DiscordKit"),
        ], swiftSettings: settings),
        .testTarget(name: "DiscordMediaBenchmarksTests", dependencies: ["DiscordMediaBenchmarks"], swiftSettings: settings),
    ])
