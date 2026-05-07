#!/usr/bin/env swift
// make_icon.swift — 生成 AIMA AppIcon.icns
// 用法: swift scripts/make_icon.swift <output.icns>

import AppKit
import Foundation

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./AppIcon.icns"

/// 绘制单张尺寸图标
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // 圆角矩形背景（蓝→紫渐变）
    let inset: CGFloat = size * 0.10
    let rect = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
    let radius = size * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.30, green: 0.50, blue: 1.00, alpha: 1.0),
        NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.95, alpha: 1.0)
    ])!
    grad.draw(in: rect, angle: -60)

    // "AIMA" 文本（粗体）
    let fontSize = size * 0.28
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
        .kern: size * 0.01
    ]
    let text = "AIMA" as NSString
    let textSize = text.size(withAttributes: attrs)
    let textRect = NSRect(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2 - size * 0.02,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect, withAttributes: attrs)

    // 小波形装饰（底部）暗示"语音"
    let waveBaseY = size * 0.28
    let waveWidth = size * 0.36
    let waveStartX = (size - waveWidth) / 2
    NSColor.white.withAlphaComponent(0.55).setStroke()
    let waveLine = NSBezierPath()
    waveLine.lineWidth = max(1, size * 0.018)
    waveLine.lineCapStyle = .round
    let bars = 7
    for i in 0..<bars {
        let x = waveStartX + CGFloat(i) * (waveWidth / CGFloat(bars - 1))
        let h = size * (0.03 + 0.055 * CGFloat((i % 3 == 0) ? 2 : (i % 2 == 0 ? 1 : 0)))
        waveLine.move(to: NSPoint(x: x, y: waveBaseY - h))
        waveLine.line(to: NSPoint(x: x, y: waveBaseY + h))
    }
    waveLine.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 1)
    }
    try data.write(to: url)
}

// 生成 iconset
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("aima_iconset_\(UUID().uuidString)")
let iconsetDir = tmpDir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// (pt, @scale, filename)
let specs: [(Int, Int, String)] = [
    (16,  1, "icon_16x16.png"),
    (16,  2, "icon_16x16@2x.png"),
    (32,  1, "icon_32x32.png"),
    (32,  2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png")
]

for (pt, scale, name) in specs {
    let px = CGFloat(pt * scale)
    let rep = drawIcon(size: px)
    try save(rep: rep, to: iconsetDir.appendingPathComponent(name))
}

// iconutil 打包 .icns
let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconsetDir.path, "-o", outURL.path]
try task.run()
task.waitUntilExit()

try? FileManager.default.removeItem(at: tmpDir)

if task.terminationStatus != 0 {
    FileHandle.standardError.write("iconutil 失败".data(using: .utf8)!)
    exit(1)
}
print("✓ 已生成 \(outURL.path)")
