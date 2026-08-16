// アプリアイコンを生成する。デザインツールを使わず、実行するたび同じ絵が出る。
//
//   swift make-icon.swift out.png [size]
//
// 図像は「日没の空に立つ電源記号」。終業（日が落ちる）と電源を切ることの
// 両方を1つの形にしている。16pt でも潰れないよう、要素は3つに絞ってある。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.png> [size]\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[1]
let size = args.count >= 3 ? (Int(args[2]) ?? 1024) : 1024

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// 記事・マニュアルと同じ色域（夜の紺 → 日没の琥珀）
let skyTop    = rgb(14, 18, 28)
let skyMid    = rgb(32, 42, 66)
let skyLow    = rgb(120, 74, 62)
let ember     = rgb(226, 138, 60)
let emberLite = rgb(247, 194, 124)
let ground    = rgb(10, 13, 20)

let scale = Double(size) / 1024.0
let S = Double(size)

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

ctx.interpolationQuality = .high
ctx.setAllowsAntialiasing(true)

// --- 本体の角丸（macOS のアイコングリッドに合わせて内側に寄せる） ---
let body = 824.0 * scale
let inset = (S - body) / 2
let radius = 185.0 * scale
let bodyRect = CGRect(x: inset, y: inset, width: body, height: body)
let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()

// 空のグラデーション
let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                     colors: [skyTop, skyMid, skyLow] as CFArray,
                     locations: [0.0, 0.55, 1.0])!
ctx.drawLinearGradient(sky,
                       start: CGPoint(x: 0, y: bodyRect.maxY),
                       end: CGPoint(x: 0, y: bodyRect.minY),
                       options: [])

// 地平線より下は暗く落とす
let horizonY = bodyRect.minY + body * 0.24
ctx.setFillColor(ground)
ctx.fill(CGRect(x: bodyRect.minX, y: bodyRect.minY, width: body, height: horizonY - bodyRect.minY))

// 地平線のきわに光の帯
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [ember.copy(alpha: 0.0)!, emberLite.copy(alpha: 0.85)!] as CFArray,
                      locations: [0.0, 1.0])!
ctx.saveGState()
ctx.clip(to: CGRect(x: bodyRect.minX, y: horizonY, width: body, height: body * 0.15))
ctx.drawLinearGradient(glow,
                       start: CGPoint(x: 0, y: horizonY + body * 0.15),
                       end: CGPoint(x: 0, y: horizonY),
                       options: [])
ctx.restoreGState()

// --- 電源記号（琥珀色）---
let cx = bodyRect.midX
let cy = bodyRect.minY + body * 0.60
let ringR = body * 0.215
let lineW = body * 0.088

ctx.setLineCap(.round)
ctx.setLineWidth(lineW)
ctx.setStrokeColor(emberLite)

// 上を 60 度あけたリング
let gap = 30.0 * .pi / 180.0
ctx.beginPath()
ctx.addArc(center: CGPoint(x: cx, y: cy), radius: ringR,
           startAngle: .pi / 2 + gap, endAngle: .pi / 2 - gap,
           clockwise: false)
ctx.strokePath()

// 中央の縦棒
ctx.beginPath()
ctx.move(to: CGPoint(x: cx, y: cy + ringR * 0.12))
ctx.addLine(to: CGPoint(x: cx, y: cy + ringR * 1.16))
ctx.strokePath()

ctx.restoreGState()

// --- 書き出し ---
guard let image = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
