// Clampless 앱 아이콘(1024x1024 PNG) 생성 스크립트
// 사용: swift Scripts/make_icon.swift <출력.png>
// 컨셉: 밤하늘 배경 + 덮개가 닫힌 맥북 + 그 위에서 깨어 있는 해(☀︎)

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("bitmap 생성 실패") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// 1) macOS 아이콘 그리드: 1024 캔버스 안의 824 둥근 사각형 + 그림자
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
tileShadow.shadowBlurRadius = 28
tileShadow.shadowOffset = NSSize(width: 0, height: -12)
tileShadow.set()
color(0x101833).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

// 2) 밤하늘 그라디언트
NSGradient(colors: [color(0x3A4C8C), color(0x1B2550), color(0x0C1230)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: tilePath, angle: -90)

// 3) 작은 별들
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (230, 800, 7, 0.9), (300, 690, 4, 0.6), (790, 820, 6, 0.8),
    (840, 700, 4, 0.5), (720, 760, 3, 0.5), (190, 600, 3, 0.4), (860, 560, 3, 0.4),
]
for (x, y, r, a) in stars {
    color(0xFFFFFF, a).setFill()
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
}

// 4) 해 뒤의 은은한 빛
let glowCenter = NSPoint(x: 512, y: 590)
NSGradient(colors: [color(0xFFC94A, 0.55), color(0xFFC94A, 0.0)])!
    .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 330, options: [])
NSGraphicsContext.restoreGraphicsState()

// 5) 해 (SF Symbol)
let sunConfig = NSImage.SymbolConfiguration(pointSize: 300, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [color(0xFFD25C)]))
if let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(sunConfig) {
    let s = sun.size
    let scale = 400 / max(s.width, s.height)
    let w = s.width * scale, h = s.height * scale
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xFFB020, 0.9)
    glow.shadowBlurRadius = 40
    glow.shadowOffset = .zero
    glow.set()
    sun.draw(in: NSRect(x: glowCenter.x - w / 2, y: glowCenter.y - h / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
}

// 6) 덮개가 닫힌 맥북 (정면에서 본 얇은 판 두 겹)
NSGraphicsContext.saveGraphicsState()
let laptopShadow = NSShadow()
laptopShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
laptopShadow.shadowBlurRadius = 24
laptopShadow.shadowOffset = NSSize(width: 0, height: -10)
laptopShadow.set()

let base = NSRect(x: 192, y: 268, width: 640, height: 34)       // 하판
let lid = NSRect(x: 212, y: 300, width: 600, height: 46)        // 닫힌 덮개
let basePath = NSBezierPath(roundedRect: base, xRadius: 17, yRadius: 17)
let lidPath = NSBezierPath(roundedRect: lid, xRadius: 14, yRadius: 14)
color(0x9EA5B3).setFill()
basePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [color(0xC9CED8), color(0x8D94A3)])!.draw(in: basePath, angle: -90)
NSGradient(colors: [color(0xF4F6FA), color(0xC3C8D2)])!.draw(in: lidPath, angle: -90)

// 덮개와 하판 사이 틈
color(0x5B6170, 0.8).setFill()
NSBezierPath(rect: NSRect(x: 222, y: 298, width: 580, height: 3)).fill()
// 하판 앞쪽 손가락 홈
color(0x6E7484, 0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: 462, y: 296, width: 100, height: 8), xRadius: 4, yRadius: 4).fill()
// 덮개 윗면 하이라이트
color(0xFFFFFF, 0.7).setFill()
NSBezierPath(roundedRect: NSRect(x: 232, y: 338, width: 560, height: 4), xRadius: 2, yRadius: 2).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 인코딩 실패") }
try png.write(to: URL(fileURLWithPath: out))
print("생성: \(out)")
