import SwiftUI
import Combine

/// Effects stay in a Canvas subtree. They never publish animation frames into
/// the omnibar, inspect web content, or intercept pointer/keyboard events.
struct OmnibarWeatherScene: View {
    enum Layer { case sky, precipitation }
    let layer: Layer
    var surfaces: [CGRect] = []
    var attributionVisible = false
    @ObservedObject private var store = NewspaperWeatherStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(OmnibarMotionPreferences.durationKey) private var duration = OmnibarMotionPreferences.defaultDuration
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var started = Date()
    @State private var revealed = false

    var body: some View {
        // Credit lives in the forecast panel, always outside its scrolling area.
        // Decorative effects do not cover or obscure that panel's attribution.
        let profile = (attributionVisible && store.hasSceneAttribution) || OmnibarWeatherSnapshot.testPreview != nil ? store.scene : nil
        let animated = profile != nil && !reduceMotion && duration > 0 && scenePhase != .background
        TimelineView(.animation(minimumInterval: lowPower ? 1 / 12 : 1 / 30, paused: !animated)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                guard let profile, size.width > 0, size.height > 0 else { return }
                let time = animated ? timeline.date.timeIntervalSince(started) : 0
                if layer == .sky {
                    drawSky(context: &context, size: size, profile: profile, time: time)
                } else {
                    drawWeather(context: &context, size: size, profile: profile, time: time, compact: lowPower)
                }
            }
        }
        .modifier(OmnibarWeatherCurtain(progress: revealed ? 0 : 1))
        .omnibarMotion(revealed)
        .onChange(of: profile != nil, initial: true) { _, ready in
            if ready { started = Date() }
            revealed = ready
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func seed(_ index: Int, _ salt: Double = 0) -> Double {
        let value = sin(Double(index) * 127.1 + salt * 311.7) * 43758.5453
        return value - floor(value)
    }
    private func drawSky(context: inout GraphicsContext, size: CGSize, profile: OmnibarWeatherSnapshot, time: Double) {
        let top: Color = profile.daylight ? Color(red: 0.15, green: 0.39, blue: 0.57) : Color(red: 0.02, green: 0.04, blue: 0.13)
        let bottom: Color = profile.goldenHour ? Color(red: 0.65, green: 0.3, blue: 0.24)
            : profile.daylight ? Color(red: 0.37, green: 0.54, blue: 0.6) : Color(red: 0.13, green: 0.18, blue: 0.31)
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        if !profile.daylight {
            for index in 0..<65 {
                let point = CGPoint(x: seed(index) * size.width, y: seed(index, 2) * size.height * 0.62)
                let radius = 0.5 + seed(index, 4)
                let opacity = (0.25 + 0.4 * (0.5 + 0.5 * sin(time * 0.5 + Double(index)))) * (1 - profile.cloudCover * 0.75)
                context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: radius * 2, height: radius * 2)),
                             with: .color(.white.opacity(opacity)))
            }
        }
        let solar = profile.solarProgress
        let orb = CGRect(x: size.width * (profile.daylight ? 0.14 + solar * 0.72 : 0.78),
            y: size.height * (profile.daylight ? 0.6 - sin(solar * .pi) * 0.5 : 0.09) + sin(time * 0.15) * 3,
            width: 64, height: 64)
        context.fill(Path(ellipseIn: orb.insetBy(dx: -22, dy: -22)), with: .radialGradient(
            Gradient(colors: [Color.yellow.opacity(profile.daylight ? 0.24 : 0.06), .clear]),
            center: CGPoint(x: orb.midX, y: orb.midY), startRadius: 25, endRadius: 60))
        context.fill(Path(ellipseIn: orb), with: .color(profile.daylight ? .yellow.opacity(0.8) : .white.opacity(0.85)))
        if !profile.daylight {
            context.fill(Path(ellipseIn: orb.offsetBy(dx: 18, dy: -10)), with: .color(top))
        }
        for index in 0..<8 {
            let width = 150 + seed(index, 8) * 210
            let drift = time * (2 + profile.wind * 0.6) * profile.windSign
            let x = (seed(index, 6) * (size.width + width) + drift).truncatingRemainder(dividingBy: size.width + width)
            let y = size.height * (0.08 + seed(index, 7) * 0.38) + sin(time * 0.25 + Double(index)) * 6
            let rect = CGRect(x: x - width, y: y, width: width, height: width * 0.25)
            var cloud = Path()
            cloud.addEllipse(in: rect)
            cloud.addEllipse(in: CGRect(x: rect.minX + width * 0.15, y: y - width * 0.1, width: width * 0.4, height: width * 0.3))
            cloud.addEllipse(in: CGRect(x: rect.minX + width * 0.4, y: y - width * 0.16, width: width * 0.45, height: width * 0.38))
            context.fill(cloud, with: .color(.white.opacity((0.05 + profile.cloudCover * 0.16) * (profile.daylight ? 1 : 0.6))))
        }
        for index in 0..<3 {
            var hill = Path()
            let y = size.height * (0.82 + Double(index) * 0.055)
            hill.move(to: CGPoint(x: 0, y: y))
            hill.addCurve(to: CGPoint(x: size.width, y: y + 35),
                control1: CGPoint(x: size.width * 0.33, y: y - 65),
                control2: CGPoint(x: size.width * 0.68, y: y + 40))
            hill.addLine(to: CGPoint(x: size.width, y: size.height))
            hill.addLine(to: CGPoint(x: 0, y: size.height)); hill.closeSubpath()
            context.fill(hill, with: .color(Color(red: 0.02, green: 0.07, blue: 0.1).opacity(0.3 + Double(index) * 0.15)))
        }
    }
    private func landingY(x: Double, size: CGSize) -> Double {
        Double(surfaces.filter { !$0.isEmpty && $0.minY > 0 && x >= $0.minX && x <= $0.maxX }
            .map(\.minY).min() ?? (size.height - 12))
    }
    private func drawWeather(context: inout GraphicsContext, size: CGSize, profile: OmnibarWeatherSnapshot,
                             time: Double, compact: Bool) {
        // Let particles land on surfaces, keeping their contents and Apple's
        // attribution clear even when wind carries leaves across the scene.
        var exposed = Path(CGRect(origin: .zero, size: size))
        for surface in surfaces where !surface.isEmpty { exposed.addRect(surface) }
        context.clip(to: exposed, style: FillStyle(eoFill: true))
        let gust = profile.windSign * min(45, profile.wind * 3) * (0.7 + sin(time * 0.6) * 0.3)
        if profile.isRaining || profile.isSnowing {
            let snow = profile.isSnowing && !profile.isRaining
            let count = compact ? 40 : snow ? 90 : 150
            for index in 0..<count {
                let x = seed(index, 15) * size.width
                let ground = landingY(x: x, size: size)
                let speed = snow ? 0.08 + seed(index, 3) * 0.08 : 0.55 + seed(index, 3) * 0.5
                let phase = (time * speed + seed(index, 12)).truncatingRemainder(dividingBy: 1)
                let y = -30 + phase * (ground + 30)
                let drift = gust * sin(phase * .pi) + (snow ? sin(time * 0.9 + Double(index)) * 12 : 0)
                let point = CGPoint(x: x + drift, y: y)
                if snow {
                    let radius = 1.5 + seed(index, 5) * 2
                    context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: radius * 2, height: radius * 2)),
                                 with: .color(.white.opacity(0.45 + seed(index, 9) * 0.45)))
                } else {
                    var drop = Path()
                    drop.move(to: point)
                    drop.addLine(to: CGPoint(x: point.x + gust * 0.14, y: min(ground, point.y + 8 + seed(index, 5) * 12)))
                    context.stroke(drop, with: .color(.cyan.opacity(0.28)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    if phase > 0.9 {
                        let splash = (phase - 0.9) * 10
                        var arc = Path()
                        arc.move(to: CGPoint(x: x - 5 * splash, y: ground - 2 * sin(splash * .pi)))
                        arc.addQuadCurve(to: CGPoint(x: x + 5 * splash, y: ground),
                                         control: CGPoint(x: x, y: ground - 6 * sin(splash * .pi)))
                        context.stroke(arc, with: .color(.white.opacity((1 - splash) * 0.45)), lineWidth: 0.8)
                    }
                }
            }
        }
        if profile.snowDepth > 0 {
            for rect in surfaces.filter({ $0.width > 40 && $0.minY > 0 }) {
                var bank = Path()
                let depth = profile.snowDepth + (profile.isSnowing ? min(4, time * 0.1) : 0)
                bank.move(to: CGPoint(x: rect.minX + 14, y: rect.minY))
                for step in 0...24 {
                    let x = rect.minX + 14 + (rect.width - 28) * Double(step) / 24
                    let height = depth * (0.7 + 0.3 * sin(Double(step) * 0.65))
                    bank.addLine(to: CGPoint(x: x, y: rect.minY - height))
                }
                bank.addLine(to: CGPoint(x: rect.maxX - 14, y: rect.minY)); bank.closeSubpath()
                context.fill(bank, with: .color(.white.opacity(0.85)))
            }
        }
        if max(profile.wind, profile.recentWind) >= 4 {
            for index in 0..<(compact ? 4 : 9) {
                let phase = (time * 0.12 + seed(index, 24)).truncatingRemainder(dividingBy: 1)
                let x = profile.windSign > 0 ? phase * (size.width + 200) - 100 : size.width + 100 - phase * (size.width + 200)
                let y = seed(index, 21) * size.height + sin(phase * .pi * 2) * 35
                var breeze = Path()
                breeze.move(to: CGPoint(x: x, y: y))
                breeze.addCurve(to: CGPoint(x: x + 90, y: y - 8),
                    control1: CGPoint(x: x + 25, y: y - 14), control2: CGPoint(x: x + 60, y: y + 12))
                context.stroke(breeze, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
        }
        if profile.hasLeaves {
            for index in 0..<(compact ? 8 : 22) {
                let phase = (time * (0.06 + seed(index, 33) * 0.06) + seed(index, 31)).truncatingRemainder(dividingBy: 1)
                let x = profile.windSign > 0 ? phase * (size.width + 100) - 50 : size.width + 50 - phase * (size.width + 100)
                let y = seed(index, 32) * size.height + sin(phase * 10 + Double(index)) * 35
                var leafContext = context
                leafContext.translateBy(x: x, y: y)
                leafContext.rotate(by: .radians(time * 1.5 + Double(index)))
                leafContext.scaleBy(x: 0.6 + abs(sin(time + Double(index))) * 0.4, y: 1)
                var leaf = Path()
                leaf.move(to: CGPoint(x: -7, y: 0))
                leaf.addQuadCurve(to: CGPoint(x: 7, y: 0), control: CGPoint(x: 0, y: -9))
                leaf.addQuadCurve(to: CGPoint(x: -7, y: 0), control: CGPoint(x: 0, y: 7))
                leafContext.fill(leaf, with: .color(index.isMultiple(of: 3) ? .orange.opacity(0.75) : .yellow.opacity(0.6)))
            }
        }
    }
}

/// A curtain rolls down from the actual viewport edge, with a small sideways
/// squeeze. The field is kept mounted and focused throughout this transition.
struct OmnibarWeatherCurtain: AnimatableModifier {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        content.scaleEffect(x: 1 - progress * 0.055, y: 1, anchor: .top)
            .offset(x: sin(progress * .pi) * 8)
            .mask(GeometryReader { proxy in
                Rectangle().frame(height: proxy.size.height * max(0, min(1, 1 - progress))).frame(maxHeight: .infinity, alignment: .top)
            })
            .opacity(1 - progress * 0.5)
    }
    static var transition: AnyTransition {
        .modifier(active: Self(progress: 1), identity: Self(progress: 0))
    }
}
