// アプリアイコンを生成する。デザインツールを使わず、実行するたび同じ絵が出る。
//
//   swift make-icon.swift out.png [size]
//
// 図像は「無地の地に電源記号」だけ。以前は日没の空を背にしていたが、太陽や
// 月、空の色を持ち込むと天気や日の入り時刻のアプリに見えてしまうので外した。
// 地は色味の無い黒鉄色にして、何のアプリかは記号だけで伝える。

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

// 色味の無いグレー。空や夕焼けを連想させる青・琥珀は使わない
let baseTop    = rgb(58, 58, 62)
let baseBottom = rgb(24, 24, 27)
let symbol     = rgb(242, 242, 245)

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

// 上から下へわずかに暗くなるだけの地
let base = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [baseTop, baseBottom] as CFArray,
                      locations: [0.0, 1.0])!
ctx.drawLinearGradient(base,
                       start: CGPoint(x: 0, y: bodyRect.maxY),
                       end: CGPoint(x: 0, y: bodyRect.minY),
                       options: [])

// --- 電源記号（中央）---
// 縦棒がリングの上へ突き出すぶん、見た目の重心が上に寄るので少し下げる
let cx = bodyRect.midX
let cy = bodyRect.midY - body * 0.03
let ringR = body * 0.25
let lineW = body * 0.095

ctx.setLineCap(.round)
ctx.setLineWidth(lineW)
ctx.setStrokeColor(symbol)

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
