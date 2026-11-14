// Draws the Rulebook mark and writes everything made from it: the layers of Resources/AppIcon.icon,
// which Xcode compiles into the app icon, and the logo files in docs/logo.
//
//     swift scripts/make-icon.swift
//
// The mark is a capital R held by the three lines of ruled writing paper: cap height, a dashed
// midline and the baseline. Those lines are rules, and the letter is drawn the way such paper
// teaches it, from a stem, a bowl and a leg.
import AppKit

// MARK: Geometry, on a 1024 canvas with y up

let canvas: CGFloat = 1024
let baseline: CGFloat = 276
let capHeight: CGFloat = 748
let midline: CGFloat = (baseline + capHeight) / 2
let weight: CGFloat = 92          // the letter's stroke
let ruleWeight: CGFloat = 24      // the guidelines: a quarter of the letter's stroke, so they still show in the Dock
let smallRuleWeight: CGFloat = 38 // and heavier where the icon is drawn a few millimetres wide
let stemLeft: CGFloat = 316       // places the letter so it looks centered

let letter: CGPath = {
    let half = weight / 2
    let stem = CGPath(rect: CGRect(x: stemLeft, y: baseline, width: weight, height: capHeight - baseline), transform: nil)

    // The bowl runs from the top of the stem around to the midline, where its lower stroke is centered.
    let radius = (capHeight - half - midline) / 2
    let bowlLine = CGMutablePath()
    bowlLine.move(to: CGPoint(x: stemLeft + half, y: capHeight - half))
    bowlLine.addLine(to: CGPoint(x: stemLeft + half + 150, y: capHeight - half))
    bowlLine.addArc(center: CGPoint(x: stemLeft + half + 150, y: midline + radius), radius: radius,
                    startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
    bowlLine.addLine(to: CGPoint(x: stemLeft + half, y: midline))
    let bowl = bowlLine.copy(strokingWithWidth: weight, lineCap: .butt, lineJoin: .miter, miterLimit: 4)

    // The leg is drawn long, then cut flat at the baseline and under the bowl.
    let from = CGPoint(x: stemLeft + half + 120, y: midline), to = CGPoint(x: stemLeft + half + 300, y: baseline)
    let legLine = CGMutablePath()
    legLine.move(to: CGPoint(x: from.x - (to.x - from.x) / 2, y: from.y - (to.y - from.y) / 2))
    legLine.addLine(to: CGPoint(x: to.x + (to.x - from.x) / 2, y: to.y + (to.y - from.y) / 2))
    let leg = legLine.copy(strokingWithWidth: weight, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
        .intersection(CGPath(rect: CGRect(x: 0, y: baseline, width: canvas, height: midline - baseline), transform: nil))

    return stem.union(bowl).union(leg).normalized()
}()

/// The guidelines, from `minX` to `maxX`. The dashes are centered so both edges end the same way.
func guides(from minX: CGFloat, to maxX: CGFloat, weight ruleWeight: CGFloat = ruleWeight) -> CGPath {
    let p = CGMutablePath()
    for y in [capHeight, baseline] {
        p.addRect(CGRect(x: minX, y: y - ruleWeight / 2, width: maxX - minX, height: ruleWeight))
    }
    let dash = ruleWeight * 4.4, period = ruleWeight * 7.8
    let center = (minX + maxX) / 2
    var x = center - dash / 2 - period * ((center - minX) / period).rounded(.up)
    while x < maxX {
        let start = max(x, minX), end = min(x + dash, maxX)
        if end > start { p.addRect(CGRect(x: start, y: midline - ruleWeight / 2, width: end - start, height: ruleWeight)) }
        x += period
    }
    return p
}
let rules = guides(from: 0, to: canvas)

// MARK: Colors

struct Ink {
    let red: CGFloat, green: CGFloat, blue: CGFloat
    init(_ hex: UInt32) {
        red = CGFloat((hex >> 16) & 0xFF) / 255
        green = CGFloat((hex >> 8) & 0xFF) / 255
        blue = CGFloat(hex & 0xFF) / 255
    }
    var hex: String { String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255)) }
    var icon: String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", red, green, blue) }
    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

let paper = Ink(0xFFFFFF), paperShade = Ink(0xF1EFEA)
let black = Ink(0x17181A)
let ruleBlue = Ink(0x8DB9EA)              // the blue of ruled paper
let night = Ink(0x2B2D31), nightShade = Ink(0x141517)
let ruleBlueOnDark = Ink(0x4E7FB5)
let white = Ink(0xF7F6F3)

// MARK: SVG

func svgData(_ path: CGPath, dx: CGFloat = 0, dy: CGFloat = 0) -> String {
    func f(_ p: CGPoint) -> String { String(format: "%.2f %.2f", p.x + dx, canvas - p.y + dy) }
    var d = ""
    path.applyWithBlock { e in
        let pts = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(f(pts[0]))"
        case .addLineToPoint: d += "L\(f(pts[0]))"
        case .addQuadCurveToPoint: d += "Q\(f(pts[0])) \(f(pts[1]))"
        case .addCurveToPoint: d += "C\(f(pts[0])) \(f(pts[1])) \(f(pts[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func write(_ text: String, to path: String) {
    let url = URL(fileURLWithPath: path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

// Icon Composer layers: one shape each, on the full canvas. icon.json gives them their colors.
func layer(_ path: CGPath) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <path d="\(svgData(path))" fill="#000"/>
    </svg>

    """
}
func fills(_ light: Ink, dark: Ink) -> String {
    """
    [
                { "value" : { "solid" : "\(light.icon)" } },
                { "appearance" : "dark", "value" : { "solid" : "\(dark.icon)" } },
                { "appearance" : "tinted", "value" : { "solid" : "\(dark.icon)" } }
              ]
    """
}
write(layer(letter), to: "Resources/AppIcon.icon/Assets/letter.svg")
write(layer(rules), to: "Resources/AppIcon.icon/Assets/rules.svg")
write("""
{
  "fill-specializations" : [
    { "value" : { "linear-gradient" : ["\(paper.icon)", "\(paperShade.icon)"] } },
    { "appearance" : "dark", "value" : { "linear-gradient" : ["\(night.icon)", "\(nightShade.icon)"] } }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "fill-specializations" : \(fills(black, dark: white)),
          "glass" : true,
          "image-name" : "letter.svg",
          "name" : "letter"
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.3 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    },
    {
      "layers" : [
        {
          "fill-specializations" : \(fills(ruleBlue, dark: ruleBlueOnDark)),
          "glass" : false,
          "image-name" : "rules.svg",
          "name" : "rules"
        }
      ],
      "shadow" : { "kind" : "none", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : ["macOS"] }
}

""", to: "Resources/AppIcon.icon/icon.json")

// The logo: the letter on a short length of its rules, cropped to fit.
func mark(letter letterFill: String, rules ruleFill: String, ruleOpacity: String = "") -> String {
    let box = letter.boundingBoxOfPath.insetBy(dx: -84, dy: -ruleWeight / 2)
    let dx = -box.minX, dy = box.maxY - canvas
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(box.width.rounded()))" height="\(Int(box.height.rounded()))" viewBox="0 0 \(String(format: "%.2f %.2f", box.width, box.height))" role="img" aria-label="Rulebook">
      <path d="\(svgData(guides(from: box.minX, to: box.maxX), dx: dx, dy: dy))" fill="\(ruleFill)"\(ruleOpacity)/>
      <path d="\(svgData(letter, dx: dx, dy: dy))" fill="\(letterFill)"/>
    </svg>

    """
}
write(mark(letter: black.hex, rules: ruleBlue.hex), to: "docs/logo/mark.svg")
write(mark(letter: white.hex, rules: ruleBlueOnDark.hex), to: "docs/logo/mark-on-dark.svg")
write(mark(letter: "currentColor", rules: "currentColor", ruleOpacity: " opacity=\"0.35\""), to: "docs/logo/mark-one-color.svg")

// The icon for small sizes, such as beside the name on the website and in a browser tab: the same tile with
// heavier rules, and an outline, because on the site's paper a paper tile has no edge of its own.
func smallIcon(top: Ink, bottom: Ink, letter letterFill: Ink, rules ruleFill: Ink, outline: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="Rulebook">
      <defs>
        <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(top.hex)"/><stop offset="1" stop-color="\(bottom.hex)"/></linearGradient>
        <clipPath id="edge"><rect width="1024" height="1024" rx="232"/></clipPath>
      </defs>
      <g clip-path="url(#edge)">
        <rect width="1024" height="1024" fill="url(#tile)"/>
        <path d="\(svgData(guides(from: 0, to: canvas, weight: smallRuleWeight)))" fill="\(ruleFill.hex)"/>
        <path d="\(svgData(letter))" fill="\(letterFill.hex)"/>
      </g>
      <rect x="16" y="16" width="992" height="992" rx="216" fill="none" stroke="\(outline)" stroke-width="32"/>
    </svg>

    """
}
write(smallIcon(top: paper, bottom: paperShade, letter: black, rules: ruleBlue, outline: "rgba(23,24,26,0.16)"), to: "docs/logo/icon-small.svg")
write(smallIcon(top: night, bottom: nightShade, letter: white, rules: ruleBlueOnDark, outline: "rgba(247,246,243,0.16)"), to: "docs/logo/icon-small-dark.svg")

// MARK: A picture of the finished icon, for the README

// Icon Composer's command-line tool renders the layers the way macOS does. It comes with Xcode 26 and later.
let ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
if FileManager.default.isExecutableFile(atPath: ictool) {
    let export = Process()
    export.executableURL = URL(fileURLWithPath: ictool)
    export.arguments = ["Resources/AppIcon.icon", "--export-image", "--output-file", "docs/logo/icon.png",
                        "--platform", "macOS", "--rendition", "Default", "--width", "256", "--height", "256", "--scale", "2"]
    export.standardOutput = FileHandle.nullDevice
    export.standardError = FileHandle.nullDevice
    try? export.run()
    export.waitUntilExit()
}
