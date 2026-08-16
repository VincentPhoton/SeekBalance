// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "SeekBalance",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "SeekBalance",
      path: "Sources/SeekBalance"
    )
  ]
)
