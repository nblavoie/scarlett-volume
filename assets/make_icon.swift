// Génère l'icône de l'app (1024×1024 PNG) : bouton de volume style Scarlett
// sur squircle macOS rouge Focusrite. Usage : swift make_icon.swift
import AppKit

let S: CGFloat = 1024
let center = NSPoint(x: S / 2, y: S / 2)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("contexte graphique impossible")
}
rep.size = NSSize(width: S, height: S)
NSGraphicsContext.current = ctx

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

// Capsule orientée radialement depuis le centre (pour graduations et aiguille)
func radialCapsule(from r0: CGFloat, to r1: CGFloat, width: CGFloat, angle: CGFloat) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: NSRect(x: r0, y: -width / 2, width: r1 - r0, height: width),
                            xRadius: width / 2, yRadius: width / 2)
    var tf = AffineTransform(translationByX: center.x, byY: center.y)
    tf.rotate(byDegrees: angle)
    path.transform(using: tf)
    return path
}

// ===== Squircle macOS (824 pt centrée, marge transparente, ombre portée) =====
let squircleRect = NSRect(x: 100, y: 108, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: squircleRect, xRadius: 186, yRadius: 186)

NSGraphicsContext.current?.saveGraphicsState()
let dropShadow = NSShadow()
dropShadow.shadowOffset = NSSize(width: 0, height: -14)
dropShadow.shadowBlurRadius = 28
dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
dropShadow.set()
rgb(0.60, 0.06, 0.10).setFill()
squircle.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// Dégradé rouge Focusrite, éclairé par le haut
NSGradient(colorsAndLocations:
    (rgb(1.00, 0.44, 0.36), 0.0),
    (rgb(0.88, 0.16, 0.19), 0.45),
    (rgb(0.50, 0.03, 0.09), 1.0))!
    .draw(in: squircle, angle: -90)

// Halo doux derrière le bouton
NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()
NSGradient(colorsAndLocations:
    (NSColor.white.withAlphaComponent(0.14), 0.0),
    (NSColor.white.withAlphaComponent(0.0), 1.0))!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: center.x - 380, y: center.y - 380, width: 760, height: 760)),
          relativeCenterPosition: NSPoint(x: 0, y: 0.25))
NSGraphicsContext.current?.restoreGraphicsState()

// ===== Graduations (course 270°, min en bas-gauche, max en bas-droite) =====
let level: CGFloat = 0.72 // position de l'aiguille
let tickCount = 28
for i in 0..<tickCount {
    let t = CGFloat(i) / CGFloat(tickCount - 1)
    let angle = 225 - t * 270
    let on = t <= level
    NSColor.white.withAlphaComponent(on ? 0.95 : 0.26).setFill()
    radialCapsule(from: 330, to: on ? 372 : 362, width: on ? 13 : 10, angle: angle).fill()
}

// ===== Bouton (anthracite, comme le vrai bouton de la 2i2) =====
let knobRadius: CGFloat = 296
let knob = NSBezierPath(ovalIn: NSRect(x: center.x - knobRadius, y: center.y - knobRadius,
                                       width: knobRadius * 2, height: knobRadius * 2))
NSGraphicsContext.current?.saveGraphicsState()
let knobShadow = NSShadow()
knobShadow.shadowOffset = NSSize(width: 0, height: -12)
knobShadow.shadowBlurRadius = 36
knobShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
knobShadow.set()
rgb(0.06, 0.06, 0.08).setFill()
knob.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// Biseau extérieur
NSGradient(colorsAndLocations:
    (rgb(0.29, 0.31, 0.36), 0.0),
    (rgb(0.10, 0.11, 0.13), 0.55),
    (rgb(0.04, 0.04, 0.06), 1.0))!
    .draw(in: knob, angle: -90)

// Face intérieure
let faceRadius: CGFloat = 248
let face = NSBezierPath(ovalIn: NSRect(x: center.x - faceRadius, y: center.y - faceRadius,
                                       width: faceRadius * 2, height: faceRadius * 2))
rgb(0.02, 0.02, 0.03, 0.6).setStroke()
face.lineWidth = 6
face.stroke()
NSGradient(colorsAndLocations:
    (rgb(0.17, 0.18, 0.22), 0.0),
    (rgb(0.10, 0.11, 0.13), 0.6),
    (rgb(0.07, 0.07, 0.09), 1.0))!
    .draw(in: face, angle: -90)

// Reflets du bord (lumière venant du haut)
let rim = NSBezierPath()
rim.appendArc(withCenter: center, radius: knobRadius - 3, startAngle: 40, endAngle: 140)
rim.lineWidth = 5
rim.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.28).setStroke()
rim.stroke()
let rimLow = NSBezierPath()
rimLow.appendArc(withCenter: center, radius: knobRadius - 3, startAngle: 205, endAngle: 335)
rimLow.lineWidth = 4
rimLow.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.07).setStroke()
rimLow.stroke()

// ===== Aiguille (avec léger halo, façon LED) =====
let needleAngle = 225 - level * 270
NSGraphicsContext.current?.saveGraphicsState()
let glow = NSShadow()
glow.shadowOffset = .zero
glow.shadowBlurRadius = 18
glow.shadowColor = NSColor.white.withAlphaComponent(0.55)
glow.set()
NSColor.white.withAlphaComponent(0.97).setFill()
radialCapsule(from: 140, to: 228, width: 27, angle: needleAngle).fill()
NSGraphicsContext.current?.restoreGraphicsState()

// ===== Léger éclat en haut de la squircle =====
NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()
NSGradient(colorsAndLocations:
    (NSColor.white.withAlphaComponent(0.13), 0.0),
    (NSColor.white.withAlphaComponent(0.0), 1.0))!
    .draw(in: NSRect(x: 100, y: 620, width: 824, height: 312), angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG impossible") }
let out = URL(fileURLWithPath: "icon_1024.png", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
try! png.write(to: out)
print("OK → \(out.path)")
