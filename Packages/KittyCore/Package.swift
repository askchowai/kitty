// swift-tools-version: 6.0
import PackageDescription

// Everything that talks to a Hermes gateway and holds chat state, shared by the iOS, macOS and
// watchOS apps and by the widget extensions. No UIKit / AppKit / WatchKit in here; platform
// behaviour (Live Activities, local notifications, push registration) is injected through the
// hook protocols in Runtime/Hooks.swift.
let package = Package(
    name: "KittyCore",
    platforms: [.iOS("26.0"), .macOS("26.0"), .watchOS("26.0")],
    products: [.library(name: "KittyCore", targets: ["KittyCore"])],
    targets: [
        .target(name: "KittyCore", path: "Sources/KittyCore", swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
