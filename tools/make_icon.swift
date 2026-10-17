// Builds Facet's .icns from the artwork in facet.png. The artwork is a coloured rounded tile
// on an opaque white square; this finds the tile, drops the backdrop, and fits the tile to
// the macOS icon grid (an 824 px tile with a soft shadow on a transparent 1024 px canvas),
// so Facet sits at the same size and shape as other apps in the Dock and Finder.
// Usage: make_icon <source.png> <output.icns>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: make_icon <source.png> <output.icns>\n", stderr); exit(2) }
guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])), let art = NSBitmapImageRep(data: data) else {
    fputs("make_icon: cannot read \(args[1])\n", stderr); exit(1)
}
let w = art.pixelsWide, h = art.pixelsHigh

// The tile is the saturated part of the artwork; the backdrop and its shadow are grey.
func isTile(_ x: Int, _ y: Int) -> Bool {
    guard let c = art.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
    let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
    let lo = min(c.redComponent, c.greenComponent, c.blueComponent)
    return hi - lo > 0.25
}
func firstTile(_ points: [(Int, Int)]) -> Int? { points.firstIndex { isTile($0.0, $0.1) } }

// Straight edges, scanning in from each side through the middle (pixel rows run top-down).
let left = firstTile((0..<w).map { ($0, h / 2) }) ?? 0
let right = w - 1 - (firstTile((0..<w).reversed().map { ($0, h / 2) }) ?? 0)
let top = firstTile((0..<h).map { (w / 2, $0) }) ?? 0
let bottom = h - 1 - (firstTile((0..<h).reversed().map { (w / 2, $0) }) ?? 0)
let tileW = right - left + 1, tileH = bottom - top + 1
guard tileW > w / 2, tileH > h / 2 else { fputs("make_icon: no tile found in \(args[1])\n", stderr); exit(1) }

// Corner radius: a circular corner meets the diagonal at r * (1 - 1/sqrt 2) from the box corner.
let corners = [(left, top, 1, 1), (right, top, -1, 1), (left, bottom, 1, -1), (right, bottom, -1, -1)]
let radius = corners.map { (x, y, dx, dy) -> Double in
    let d = firstTile((0..<min(tileW, tileH) / 2).map { (x + $0 * dx, y + $0 * dy) }) ?? 0
    return Double(d) / (1 - 1 / 2.squareRoot())
}.max() ?? 0

// Apple's macOS icon grid: an 824 px tile centred on a 1024 px canvas.
let canvas = 1024, tile = 824.0
let scale = tile / Double(max(tileW, tileH))
// A slightly larger radius keeps the clip inside the artwork's own rounded corner.
let clipRadius = min(tile / 2, radius * scale * 1.04)
let body = NSRect(x: 100, y: 112, width: tile, height: tile)  // a little high, leaving room for the shadow

func bitmap(_ size: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}
func draw(into rep: NSBitmapImageRep, _ body: (CGContext) -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    body(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
}

let master = bitmap(canvas)
let artImage = NSImage(size: NSSize(width: w, height: h)); artImage.addRepresentation(art)
// Bitmap rows run top-down; NSImage coordinates run bottom-up.
let crop = NSRect(x: left, y: h - 1 - bottom, width: tileW, height: tileH)
draw(into: master) { cg in
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    NSBezierPath(roundedRect: body, xRadius: clipRadius, yRadius: clipRadius).addClip()
    artImage.draw(in: body, from: crop, operation: .copy, fraction: 1)
    cg.endTransparencyLayer()
}

// Each pixel size is stored once; macOS picks representations by pixel size. The 1024 px
// size is left out: the artwork's fine texture makes it ~900 KB, most of the bundle's
// non-code weight, and macOS scales the 512 px one for the rare 512 pt Retina view.
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Facet-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
let masterImage = NSImage(size: NSSize(width: canvas, height: canvas)); masterImage.addRepresentation(master)
for (pixels, name) in [(16, "icon_16x16"), (32, "icon_32x32"), (64, "icon_32x32@2x"), (128, "icon_128x128"),
                       (256, "icon_256x256"), (512, "icon_512x512")] {
    let rep = bitmap(pixels)
    draw(into: rep) { _ in masterImage.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)) }
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name + ".png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", args[2]]
try iconutil.run(); iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
