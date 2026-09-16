//
//  make-icon.swift
//  esign — AppIcon 生成器
//
//  运行：swift tools/make-icon.swift
//  输出：esign/Assets.xcassets/AppIcon.appiconset/ 下的 10 张 PNG
//
//  1032 主图按 macOS 规范绘制：1024 画布，824 圆角方框居中，其余留透明。
//

import AppKit
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 可调参数

let canvas: CGFloat = 1024
let boxInset: CGFloat = 100                       // macOS 图标四周留白
let box = CGRect(x: boxInset, y: boxInset, width: canvas - boxInset * 2, height: canvas - boxInset * 2)

let wordmark = "eSign"
let fontWeight: NSFont.Weight = .heavy            // 系统字体即 SF Pro
let trackingEm: CGFloat = -0.022                  // 字距，负值收紧
let textWidthRatio: CGFloat = 0.645               // 文字宽度占方框宽度的比例

// 背景：黑色系对角渐变，左上略亮、右下纯黑
let backgroundTop: UInt32 = 0x3E3E48
let backgroundBottom: UInt32 = 0x040404
let topSheenAlpha: CGFloat = 0.16                 // 顶部柔光
let rimAlpha: CGFloat = 0.42                      // 内描边高光

// 前景：白色系竖向渐变，上白下银
let foregroundStops: [ColorStop] = [
    ColorStop(0xFFFFFF, 1.0, 0.00),
    ColorStop(0xFFFFFF, 1.0, 0.35),
    ColorStop(0xD8D8E0, 1.0, 0.70),
    ColorStop(0x8E8E99, 1.0, 1.00)
]

// MARK: - 工具

struct ColorStop {
    let hex: UInt32
    let alpha: CGFloat
    let location: CGFloat

    init(_ hex: UInt32, _ alpha: CGFloat = 1, _ location: CGFloat) {
        self.hex = hex
        self.alpha = alpha
        self.location = location
    }
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha
        ]
    )!
}

func gradient(_ stops: [ColorStop]) -> CGGradient {
    CGGradient(
        colorsSpace: colorSpace,
        colors: stops.map { rgb($0.hex, $0.alpha) } as CFArray,
        locations: stops.map(\.location)
    )!
}

/// 单色到透明的渐变，用于柔光和高光描边。
func fadeGradient(_ hex: UInt32, from alpha: CGFloat, to endAlpha: CGFloat = 0) -> CGGradient {
    CGGradient(
        colorsSpace: colorSpace,
        colors: [rgb(hex, alpha), rgb(hex, endAlpha)] as CFArray,
        locations: [0, 1]
    )!
}

/// Apple 风格的连续曲率圆角（超椭圆）。纯圆角矩形在大尺寸下能看出差别。
func squircle(in rect: CGRect, exponent n: CGFloat = 5, segments: Int = 1440) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    for i in 0...segments {
        let t = CGFloat(i) / CGFloat(segments) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let point = CGPoint(
            x: rect.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n),
            y: rect.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        )
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

/// 取一段文本的字形轮廓，方便做渐变填充和投影。
func glyphPath(for line: CTLine) -> CGPath {
    let path = CGMutablePath()
    for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { continue }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let font = attributes[kCTFontAttributeName as String] else { continue }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for index in 0..<count {
            guard let glyph = CTFontCreatePathForGlyph(font as! CTFont, glyphs[index], nil) else { continue }
            path.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
        }
    }
    return path
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 PNG: \(url.lastPathComponent)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "写入 PNG 失败: \(url.lastPathComponent)"])
    }
}

// MARK: - 绘制

func makeContext(size: Int) -> CGContext {
    CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func drawIcon(in context: CGContext, compact: Bool = false) {
    let shape = squircle(in: box)

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // 背景渐变
    context.drawLinearGradient(
        gradient([ColorStop(backgroundTop, 1, 0), ColorStop(backgroundBottom, 1, 1)]),
        start: CGPoint(x: box.minX, y: box.maxY),
        end: CGPoint(x: box.minX, y: box.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // 顶部柔光，避免大面积纯黑显得死板
    context.drawRadialGradient(
        fadeGradient(0xFFFFFF, from: topSheenAlpha),
        startCenter: CGPoint(x: box.midX, y: box.maxY),
        startRadius: 0,
        endCenter: CGPoint(x: box.midX, y: box.maxY),
        endRadius: box.width * 0.85,
        options: [.drawsAfterEndLocation]
    )

    // 内描边高光：只保留描边的内侧一半
    context.saveGState()
    context.addPath(shape)
    context.setLineWidth(4.5)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        fadeGradient(0xFFFFFF, from: rimAlpha, to: 0.02),
        start: CGPoint(x: box.midX, y: box.maxY),
        end: CGPoint(x: box.midX, y: box.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    // 文字
    let font = NSFont.systemFont(ofSize: 400, weight: fontWeight)

    let attributed = NSAttributedString(
        string: wordmark,
        attributes: [
            .font: font,
            .kern: font.pointSize * trackingEm
        ]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let raw = glyphPath(for: line)
    let bounds = raw.boundingBoxOfPath

    let scale = box.width * textWidthRatio * (compact ? 1.12 : 1) / bounds.width
    var transform = CGAffineTransform(translationX: box.midX, y: box.midY)
    transform = transform.scaledBy(x: scale, y: scale)
    transform = transform.translatedBy(x: -bounds.midX, y: -bounds.midY)
    guard let text = raw.copy(using: &transform) else { return }
    let textBounds = text.boundingBoxOfPath

    // 投影：先实心填一遍，保证阴影形状干净。小尺寸会糊成一团，所以略过。
    if !compact {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -14),
            blur: 44,
            color: rgb(0x000000, 0.65)
        )
        context.addPath(text)
        context.setFillColor(rgb(0xFFFFFF))
        context.fillPath()
        context.restoreGState()
    }

    // 再用白色系渐变覆盖
    context.saveGState()
    context.addPath(text)
    context.clip()
    context.drawLinearGradient(
        gradient(foregroundStops),
        start: CGPoint(x: textBounds.midX, y: textBounds.maxY),
        end: CGPoint(x: textBounds.midX, y: textBounds.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    context.restoreGState()
}

// MARK: - 输出

let slots: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

let scriptURL = URL(fileURLWithPath: #filePath)
let outputDirectory = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("esign/Assets.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: outputDirectory.path) else {
    FileHandle.standardError.write("找不到输出目录：\(outputDirectory.path)\n".data(using: .utf8)!)
    exit(1)
}

let masterContext = makeContext(size: Int(canvas))
drawIcon(in: masterContext)
guard let master = masterContext.makeImage() else {
    FileHandle.standardError.write("主图渲染失败\n".data(using: .utf8)!)
    exit(1)
}

let compactContext = makeContext(size: Int(canvas))
drawIcon(in: compactContext, compact: true)
guard let compactMaster = compactContext.makeImage() else {
    FileHandle.standardError.write("小尺寸主图渲染失败\n".data(using: .utf8)!)
    exit(1)
}

for slot in slots {
    let source = slot.pixels <= 32 ? compactMaster : master
    let image: CGImage
    if slot.pixels == Int(canvas) {
        image = source
    } else {
        let context = makeContext(size: slot.pixels)
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: slot.pixels, height: slot.pixels))
        image = context.makeImage()!
    }
    try writePNG(image, to: outputDirectory.appendingPathComponent("\(slot.name).png"))
    print("✓ \(slot.name).png  \(slot.pixels)×\(slot.pixels)")
}
