// swift-tools-version: 5.9
import PackageDescription
import CompilerPluginSupport

// Vendored copy of eastriverlee/LLM.swift 2.1.0 with the bundled llama.cpp xcframework swapped for
// an upstream `ggml-org/llama.cpp` release build (b9840) that implements the `qwen35` architecture
// (Gated DeltaNet), which 2.1.0's engine could not load. Test target + swift-testing/docc deps are
// dropped so app dependency resolution doesn't pull a moving `main` branch; only swift-syntax (for
// the @Generatable macro) remains.
let package = Package(
    name: "LLM",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "LLM",
            targets: ["LLM"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "602.0.0-latest")
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            path: "llama.cpp/llama.xcframework"
        ),
        .macro(
            name: "LLMMacrosImplementation",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ],
            path: "Sources/LLMMacrosImplementation"
        ),
        .target(
            name: "LLMMacros",
            dependencies: [
                "LLMMacrosImplementation",
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ],
            path: "Sources/LLMMacros"
        ),
        .target(
            name: "LLM",
            dependencies: ["llama", "LLMMacros"],
            path: "Sources/LLM"
        )
    ]
)
