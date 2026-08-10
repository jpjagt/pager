//
//  PagerView.swift
//  A SwiftUI reconstruction of a mid-90s translucent-smoke plastic pager.
//
//  Requires iOS 17 / macOS 14 (inner shadows are iOS 16+, .colorEffect is 17+).
//  Drops in with no assets. Metal grain is optional — see `useMetalGrain`.
//
//  The whole thing is authored at a canonical size (Layout.canvas) and scaled
//  by the parent, so every offset below can be a plain number instead of a
//  GeometryReader fraction. Use it as:
//
//      PagerView(message: "PARTY STARTS AT 8.30")
//          .frame(width: 620, height: 450)
//

import SwiftUI
import CoreImage

// MARK: - Palette -----------------------------------------------------------

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }
}

private enum Palette {
    static let shellCore   = Color(hex: 0x5C1016)   // lit centre of the translucent body
    static let shellEdge   = Color(hex: 0x24060A)   // corners, where the plastic reads thick
    static let plateauCore = Color(hex: 0x4A0D13)
    static let plateauEdge = Color(hex: 0x1E0508)
    static let bloom       = Color(hex: 0xC81E20)   // light passing through thin flanks
    static let wellFloor   = Color(hex: 0x140306)

    static let lcdLit      = Color(hex: 0xA9D94C)
    static let lcdDim      = Color(hex: 0x7FB03A)
    static let lcdInk      = Color(hex: 0x1B2A10)

    static let ledCore     = Color(hex: 0x2BEA5C)
    static let ledDeep     = Color(hex: 0x0B7E2A)
}

// MARK: - Layout ------------------------------------------------------------

private enum Layout {
    static let canvas = CGSize(width: 620, height: 450)
}

// MARK: - Shapes ------------------------------------------------------------

/// The outer mould. A superellipse rather than a rounded rect: the sides bulge
/// slightly and the corners never flatten into a true arc, which is what a
/// two-part injection mould actually produces.
struct Superellipse: InsettableShape {
    var exponent: CGFloat = 4.2
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }

        let a = r.width / 2, b = r.height / 2
        let cx = r.midX, cy = r.midY
        let k = 2 / exponent
        let steps = 240

        var p = Path()
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let x = cx + a * pow(abs(ct), k) * (ct < 0 ? -1 : 1)
            let y = cy + b * pow(abs(st), k) * (st < 0 ? -1 : 1)
            i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
        }
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> Self {
        var s = self; s.inset += amount; return s
    }
}

/// The left rocker: a vesica with an asymmetric bulge — fatter above the
/// waist than below, which is what tips it from "lens" to "eye".
struct LensShape: InsettableShape {
    var topBulge: CGFloat = 0.52
    var bottomBulge: CGFloat = 0.40
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let left  = CGPoint(x: r.minX, y: r.midY)
        let right = CGPoint(x: r.maxX, y: r.midY)
        let up    = r.height * topBulge
        let down  = r.height * bottomBulge

        var p = Path()
        p.move(to: left)
        p.addCurve(to: right,
                   control1: CGPoint(x: r.minX + r.width * 0.22, y: r.midY - up),
                   control2: CGPoint(x: r.minX + r.width * 0.78, y: r.midY - up))
        p.addCurve(to: left,
                   control1: CGPoint(x: r.minX + r.width * 0.78, y: r.midY + down),
                   control2: CGPoint(x: r.minX + r.width * 0.22, y: r.midY + down))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> Self {
        var s = self; s.inset += amount; return s
    }
}

/// The right button: an oval with three corners. Built from three tangent
/// arcs with *independent* radii — that ratio is the whole trick. Two tight
/// (left and right), one loose (upper), so it reads as a squashed teardrop
/// rather than a stadium.
struct LozengeShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let b = rect.insetBy(dx: inset, dy: inset)
        guard b.width > 0, b.height > 0 else { return Path() }

        let a = CGPoint(x: b.minX + b.width * 0.015, y: b.midY + b.height * 0.16) // pronounced
        let c = CGPoint(x: b.maxX,                   y: b.midY - b.height * 0.12) // pronounced
        let d = CGPoint(x: b.minX + b.width * 0.34,  y: b.minY)                   // soft

        var p = Path()
        p.move(to: CGPoint(x: b.midX, y: b.minY + b.height * 0.02))
        p.addArc(tangent1End: d, tangent2End: a, radius: b.height * 0.62)
        p.addArc(tangent1End: a, tangent2End: c, radius: b.height * 0.20)
        p.addArc(tangent1End: c, tangent2End: d, radius: b.height * 0.30)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> Self {
        var s = self; s.inset += amount; return s
    }
}

// MARK: - Noise -------------------------------------------------------------

enum Noise {
    /// High-frequency grain. Slightly low-passed so clusters land at ~1.5–2px
    /// instead of 1px — the correlation is what makes it read as bead-blasted
    /// mould texture rather than digital dirt.
    static let grain: CGImage? = tile(side: 256, blur: 0.6)

    /// Low-frequency mottle: the blotchy "you can see the board through it"
    /// variation in the translucent body.
    static let mottle: CGImage? = tile(side: 128, blur: 12)

    private static func tile(side: Int, blur: Double) -> CGImage? {
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        let mono = random.applyingFilter("CIPhotoEffectMono")
        let soft = blur > 0
            ? mono.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            : mono
        // Sample away from the origin so the blur's edge clamping isn't visible.
        let crop = CGRect(x: 300, y: 300, width: side, height: side)
        return ctx.createCGImage(soft, from: crop)
    }
}

/// Set to `true` after adding Grain.metal to the target. The shader modulates
/// grain amplitude by 4·L·(1−L), collapsing it in shadows and blown highlights
/// the way real film/sensor grain does. Without it, `.overlay` blending gets
/// you a coarse approximation of the same falloff for free.
let useMetalGrain = false

// MARK: - Edge fade ---------------------------------------------------------

/// Mask with a hard outer boundary and a soft inward falloff: alpha 0 exactly
/// at the silhouette, 1 by roughly `fade` inside it.
///
/// Inset first, blur to spread back out to the true edge, then clip so nothing
/// bleeds past. Only ever applied to the *noise* — the base gradient stays
/// crisp all the way to the rim stroke, or the whole surface goes muddy.
struct SurfaceFade<S: InsettableShape>: View {
    let shape: S
    var fade: CGFloat = 14

    var body: some View {
        shape.inset(by: fade)
            .fill(.white)
            .blur(radius: fade)
            .clipShape(shape)
    }
}

/// Grain, tiled, blended, and faded to a given surface.
struct GrainSurface<S: InsettableShape>: View {
    let shape: S
    var fade: CGFloat = 14
    var opacity: Double = 0.10
    var scale: CGFloat = 1.0

    var body: some View {
        Group {
            if let cg = Noise.grain {
                Image(decorative: cg, scale: scale)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(opacity)
                    .modifier(MetalGrainIfAvailable())
            }
        }
        .mask { SurfaceFade(shape: shape, fade: fade) }
        .allowsHitTesting(false)
    }
}

private struct MetalGrainIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if useMetalGrain {
            content.colorEffect(
                ShaderLibrary.grain(.float(0.18), .float(1.6), .float(7.0))
            )
        } else {
            content
        }
    }
}

// MARK: - Surface materials -------------------------------------------------

/// A raised level: light catches the top lip, the wall falls away at the bottom.
private struct RaisedSurface<S: InsettableShape>: View {
    let shape: S
    var core: Color
    var edge: Color
    var depth: CGFloat = 6

    var body: some View {
        shape
            .fill(
                RadialGradient(colors: [core, edge], center: .init(x: 0.42, y: 0.32),
                               startRadius: 0, endRadius: 340)
                .shadow(.inner(color: .white.opacity(0.22), radius: depth * 0.5, y: depth * 0.45))
                .shadow(.inner(color: .black.opacity(0.55), radius: depth,       y: -depth * 0.8))
            )
            .overlay(shape.strokeBorder(Self.rim, lineWidth: 1.1))
    }

    static var rim: LinearGradient {
        LinearGradient(
            stops: [.init(color: .white.opacity(0.45), location: 0.00),
                    .init(color: .white.opacity(0.10), location: 0.28),
                    .init(color: .clear,               location: 0.55),
                    .init(color: .black.opacity(0.45), location: 1.00)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// A recessed level: dark along the top edge, faint bounce along the bottom.
private struct RecessedSurface<S: InsettableShape>: View {
    let shape: S
    var floor: Color = Palette.wellFloor
    var depth: CGFloat = 7

    var body: some View {
        shape
            .fill(
                floor
                    .shadow(.inner(color: .black.opacity(0.75), radius: depth,       y: depth * 0.7))
                    .shadow(.inner(color: .white.opacity(0.12), radius: depth * 0.4, y: -depth * 0.3))
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.black.opacity(0.55), .white.opacity(0.20)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            )
    }
}

// MARK: - Gloss -------------------------------------------------------------

/// The specular cap on a moulded-gloss button.
///
/// The point is that the highlight's lower boundary is an *ellipse arc that
/// doesn't follow the button outline*. Match the outline and it reads as a
/// border; mismatch it and it reads as a reflection.
private struct Gloss<S: Shape>: View {
    let shape: S
    var size: CGSize
    var strength: Double = 0.92
    var coverage: CGFloat = 0.72   // vertical extent of the reflection ellipse
    var lift: CGFloat = 0.34       // how far up it's pushed

    var body: some View {
        LinearGradient(
            stops: [.init(color: .white.opacity(strength),       location: 0.00),
                    .init(color: .white.opacity(strength * 0.38), location: 0.45),
                    .init(color: .clear,                          location: 1.00)],
            startPoint: .top, endPoint: .bottom
        )
        .mask {
            Ellipse()
                .scaleEffect(x: 1.15, y: coverage)
                .offset(y: -size.height * lift)
        }
        .clipShape(shape)
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

/// Bounce light along the lower edge — the thin bright line that stops a black
/// button from looking like a hole.
private struct BounceEdge<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        shape
            .strokeBorder(.white.opacity(0.30), lineWidth: 0.8)
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0.58),
                                       .init(color: .white, location: 1.00)],
                               startPoint: .top, endPoint: .bottom)
            )
            .allowsHitTesting(false)
    }
}

// MARK: - Buttons -----------------------------------------------------------

struct RockerButton: View {
    var size = CGSize(width: 200, height: 62)
    var onPress: (Bool) -> Void = { _ in }

    @State private var pressed: Bool? = nil   // true = right half

    private var shape: LensShape { LensShape() }

    var body: some View {
        ZStack {
            // Trough the switch sits in.
            RecessedSurface(shape: shape.inset(by: -4), depth: 6)

            // Body.
            shape.fill(
                LinearGradient(colors: [Color(white: 0.19), Color(white: 0.02)],
                               startPoint: .top, endPoint: .bottom)
            )

            Gloss(shape: shape, size: size, coverage: 0.70, lift: 0.36)
            BounceEdge(shape: shape)

            // Split seam: a narrow wedge punched out of the body.
            Rectangle()
                .frame(width: 5)
                .blur(radius: 1.2)
                .blendMode(.destinationOut)
                .rotationEffect(.degrees(4))

            // Glyphs, debossed with a dark line beneath.
            HStack(spacing: size.width * 0.30) {
                glyph { Circle().frame(width: 9, height: 9) }
                glyph { Triangle().frame(width: 12, height: 13) }
            }
        }
        .compositingGroup()
        .rotationEffect(.degrees(-3))
        .frame(width: size.width, height: size.height)
        .scaleEffect(y: pressed == nil ? 1 : 0.985)
        .shadow(color: .black.opacity(0.55), radius: 4, y: 3)
        .contentShape(shape)
    }

    private func glyph<G: View>(@ViewBuilder _ content: () -> G) -> some View {
        ZStack {
            content().foregroundStyle(.black.opacity(0.6)).offset(y: 1)
            content().foregroundStyle(.white.opacity(0.88))
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct LozengeButton: View {
    var size = CGSize(width: 150, height: 66)
    var action: () -> Void = {}

    @State private var isDown = false
    private var shape: LozengeShape { LozengeShape() }

    var body: some View {
        ZStack {
            RecessedSurface(shape: shape.inset(by: -5), depth: 7)

            shape.fill(
                LinearGradient(colors: [Color(white: 0.20), Color(white: 0.02)],
                               startPoint: .top, endPoint: .bottom)
            )

            Gloss(shape: shape, size: size, coverage: 0.66, lift: 0.33)
            BounceEdge(shape: shape)

            // Emissive green bar.
            ZStack {
                Capsule()
                    .fill(Palette.ledCore)
                    .blur(radius: 9)
                    .blendMode(.plusLighter)
                    .opacity(0.85)
                Capsule()
                    .fill(
                        LinearGradient(colors: [Palette.ledCore, Palette.ledDeep],
                                       startPoint: .top, endPoint: .bottom)
                        .shadow(.inner(color: .black.opacity(0.5), radius: 3, y: 2))
                    )
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.7))
            }
            .frame(width: size.width * 0.62, height: size.height * 0.26)
            .offset(x: size.width * 0.03, y: size.height * 0.02)
        }
        .compositingGroup()
        .frame(width: size.width, height: size.height)
        .scaleEffect(isDown ? 0.985 : 1)
        .shadow(color: .black.opacity(0.55), radius: 4, y: 3)
        .contentShape(shape)
        .onTapGesture { action() }
        .animation(.easeOut(duration: 0.08), value: isDown)
    }
}

// MARK: - Display -----------------------------------------------------------

struct LCDPanel: View {
    var message: String
    var time: String = "1:00"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(colors: [Palette.lcdLit, Palette.lcdDim],
                                   startPoint: .top, endPoint: .bottom)
                )

            // Dot-matrix substrate.
            Canvas { ctx, size in
                let step: CGFloat = 3
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)),
                             with: .color(.black.opacity(0.05)))
                    x += step
                }
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                             with: .color(.black.opacity(0.05)))
                    y += step
                }
            }
            .blendMode(.multiply)

            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "envelope.fill")
                    Text(time).font(.system(size: 18, weight: .medium, design: .rounded))
                    Text("PM").font(.system(size: 9, weight: .medium))
                        .offset(y: 4)
                    Spacer()
                    Image(systemName: "speaker.wave.2.fill")
                    Image(systemName: "lock.fill")
                    Spacer().frame(width: 20)
                    Image(systemName: "arrowtriangle.right.fill")
                }
                .font(.system(size: 13))

                Text(message)
                    .font(.system(size: 32, weight: .heavy, design: .monospaced))
                    .kerning(1.5)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.lcdInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.black.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.7), radius: 6, y: 3)
    }
}

// MARK: - Assembly ----------------------------------------------------------

struct PagerView: View {
    var message: String = "PARTY STARTS AT 8.30"
    /// Swap for your own wordmark asset. Left as a placeholder so nothing
    /// here reproduces a real manufacturer's logo.
    var wordmark: String = "PAGE ONE"
    var subMark: String = "Memo Classic"

    private var shell: Superellipse { Superellipse(exponent: 4.2) }
    private var plateau: Superellipse { Superellipse(exponent: 5.0) }

    var body: some View {
        ZStack {
            // 1. Backlight halo bleeding past the silhouette.
            shell.fill(Palette.bloom)
                .blur(radius: 26)
                .opacity(0.5)
                .blendMode(.plusLighter)
                .padding(6)

            // 2. Shell body.
            ZStack {
                RaisedSurface(shape: shell, core: Palette.shellCore,
                              edge: Palette.shellEdge, depth: 9)

                // Internal mottle.
                if let cg = Noise.mottle {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .blur(radius: 5)
                        .blendMode(.multiply)
                        .opacity(0.32)
                        .clipShape(shell)
                }

                // Thin-plastic glow where the flanks catch light.
                Group {
                    bloom(x: -258, y:  40, w: 90,  h: 210)
                    bloom(x:  258, y:  30, w: 90,  h: 210)
                    bloom(x: -210, y: 168, w: 130, h: 70)
                    bloom(x:  215, y: 172, w: 130, h: 70)
                }
                .clipShape(shell)

                GrainSurface(shape: shell, fade: 22, opacity: 0.11)
            }

            // 3. Raised top plateau.
            ZStack {
                RaisedSurface(shape: plateau, core: Palette.plateauCore,
                              edge: Palette.plateauEdge, depth: 6)
                GrainSurface(shape: plateau, fade: 10, opacity: 0.13)
            }
            .frame(width: 520, height: 350)
            .offset(y: -12)

            // 4. Content.
            VStack(spacing: 0) {
                Text(wordmark)
                    .font(.system(size: 20, weight: .black, design: .default))
                    .kerning(2.5)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.8), radius: 1, y: 1)
                    .padding(.top, 34)

                LCDPanel(message: message)
                    .frame(width: 400, height: 118)
                    .padding(.top, 12)

                HStack(spacing: 46) {
                    RockerButton()
                    LozengeButton()
                }
                .padding(.top, 26)

                // Bottom badge well.
                ZStack {
                    RecessedSurface(shape: Capsule(style: .continuous), depth: 5)
                    Text(subMark)
                        .font(.system(size: 22, weight: .regular, design: .serif))
                        .italic()
                        .foregroundStyle(.white.opacity(0.75))
                        .shadow(color: .black.opacity(0.9), radius: 1, y: 1)
                }
                .frame(width: 300, height: 44)
                .padding(.top, 20)

                Spacer(minLength: 0)
            }
            .frame(width: Layout.canvas.width, height: Layout.canvas.height)
        }
        .frame(width: Layout.canvas.width, height: Layout.canvas.height)
        .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
    }

    private func bloom(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        Ellipse()
            .fill(Palette.bloom)
            .frame(width: w, height: h)
            .blur(radius: 34)
            .blendMode(.plusLighter)
            .opacity(0.55)
            .offset(x: x, y: y)
    }
}

// Capsule is already insettable; RecessedSurface needs nothing extra for it.

#Preview {
    ZStack {
        Color(white: 0.93)
        PagerView()
            .scaleEffect(1.0)
    }
    .frame(width: 760, height: 580)
}
