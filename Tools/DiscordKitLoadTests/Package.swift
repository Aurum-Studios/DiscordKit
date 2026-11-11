// swift-tools-version: 6.4
// File: Tools/DiscordKitLoadTests/Package.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
    .defaultIsolation(nil),
]

let package = Package(
    name: "DiscordKitLoadTests",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "DiscordKit", path: "../.."), .package(path: "../DiscordBenchmarkSupport"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.1")],
    targets: [
        .executableTarget(
            name: "DiscordKitLoadTests",
            dependencies: [
                .product(name: "DiscordBenchmarkSupport", package: "DiscordBenchmarkSupport"),
                .product(name: "DiscordLogging", package: "DiscordKit"),
                .product(name: "DiscordTransport", package: "DiscordKit"),
                .product(name: "DiscordNIOTransport", package: "DiscordKit"),
                .product(name: "DiscordFoundationTransport", package: "DiscordKit"),
                .product(name: "DiscordHTTP", package: "DiscordKit"),
                .product(name: "DiscordGateway", package: "DiscordKit"),
                .product(name: "DiscordCache", package: "DiscordKit"),
                .product(name: "DiscordClient", package: "DiscordKit"),
                .product(name: "DiscordBotDSL", package: "DiscordKit"),
                .product(name: "DiscordModels", package: "DiscordKit"),
                .product(name: "DiscordCore", package: "DiscordKit"),
                .product(name: "DiscordInteractions", package: "DiscordKit"),
                .product(name: "DiscordCommands", package: "DiscordKit"),
                .product(name: "DiscordCommandDSL", package: "DiscordKit"),
                .product(name: "DiscordDSL", package: "DiscordKit"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "DiscordKitLoadTestsTests",
            dependencies: ["DiscordKitLoadTests"],
            swiftSettings: concurrencySettings
        ),
    ]
)
