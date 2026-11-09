// swift-tools-version: 5.10
import PackageDescription

// BoxPic —— 原生 macOS 图像格式转换工具。
//
// platform 写 .v14 而不是 .v26：家族约定（见 BoxShot / BoxPaste 的 Package.swift 头注释）。
// ImageIO / SwiftUI / FinderSync 用到的 API 在 macOS 14 上都齐了，26 特有的只是外观细节。
//
// 依赖说明（唯一一处第三方代码）：
//   Apple 的 ImageIO 支持 62 种输入、21 种输出，但**不支持 WebP 编码**
//   （CGImageDestinationCopyTypeIdentifiers 里没有 org.webmproject.webp，
//     WebKit 的 canvas.toDataURL('image/webp') 在 macOS 26 上也会静默退回 PNG）。
//   所以内置 libwebp 1.5.0 的编码器子集（BSD 许可，见 Sources/CLibWebP/COPYING），
//   只编 enc/dsp/utils/sharpyuv，dec 只提供头文件、不做解码（解码走系统 ImageIO）。
let package = Package(
    name: "BoxPic",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BoxPic", targets: ["BoxPic"])
    ],
    targets: [
        // libwebp 编码器（C）。路径里保持 src/ 前缀：libwebp 源码用
        // `#include "src/webp/encode.h"` 这种相对工程根的写法，改不得。
        .target(
            name: "CLibWebP",
            path: "Sources/CLibWebP",
            publicHeadersPath: "src/webp",
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags(["-Wno-unused-function"])
            ]
        ),
        .executableTarget(
            name: "BoxPic",
            dependencies: ["CLibWebP"],
            path: "Sources/BoxPic"
        )
    ]
)

// 不声明 testTarget（家族约定：本机只有 Command Line Tools，声明了会因缺 XCTest
// 连主程序都编不过）。自检走应用内 --selftest，build-app.sh 拿它当发布门禁。
