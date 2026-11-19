// swift-tools-version: 6.0
import Foundation
import PackageDescription

// sherpa-onnx's C API and onnxruntime (dylibs) and llama.cpp (static, with Metal) are in Vendor/:
// ./fetch-deps.sh puts them there.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorLib = "\(root)/Vendor/sherpa-onnx/lib"
let llamaLib = "\(root)/Vendor/llama/lib"

let package = Package(
    name: "Cadabra",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
        // The onnxruntime that comes with sherpa-onnx, called directly to get SenseVoice's per-frame scores.
        .systemLibrary(name: "COnnxRuntime", path: "Sources/COnnxRuntime"),
        .executableTarget(
            name: "Cadabra",
            dependencies: ["CSherpaOnnx", "CLlama", "COnnxRuntime"],
            path: "Sources/Cadabra",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorLib)",
                    "-L\(llamaLib)",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", vendorLib,
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .testTarget(
            name: "CadabraTests",
            dependencies: ["Cadabra"],
            path: "Tests/CadabraTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
