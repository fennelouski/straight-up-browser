import SwiftUI
import Combine
import WeatherKit

/// Effects stay in a Canvas subtree. They never publish animation frames into
/// the omnibar, inspect web content, or intercept pointer/keyboard events.
struct OmnibarWeatherScene: View {
    enum Layer { case sky, precipitation }
    let layer: Layer
    var surfaces: [CGRect] = []
    var attributionVisible = false
    var snapshot: OmnibarWeatherSnapshot? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(OmnibarMotionPreferences.durationKey) private var duration = OmnibarMotionPreferences.defaultDuration
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var started = Date()

    var body: some View {
        // Credit lives in the forecast panel, always outside its scrolling area.
        // Decorative effects do not cover or obscure that panel's attribution.
        let profile = attributionVisible ? snapshot : nil
        let animated = profile != nil && !reduceMotion && duration > 0 && scenePhase != .background
        TimelineView(.animation(minimumInterval: lowPower ? 1 / 12 : 1 / 30, paused: !animated)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                guard let profile, size.width > 0, size.height > 0 else { return }
                let time = animated ? max(0, timeline.date.timeIntervalSince(started)) : 20
                if layer == .sky {
                    drawSky(context: &context, size: size, profile: profile, time: time)
                } else {
                    drawWeather(context: &context, size: size, profile: profile, time: time, compact: lowPower)
                }
            }
        }
        .onChange(of: profile.map { $0.city + $0.condition.rawValue + String($0.date.timeIntervalSince1970) }, initial: true) { _, _ in started = Date() }
        .onChange(of: animated) { _, _ in started = Date() }
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
        context.opacity = min(1, time / 2)
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
            y: size.height * (profile.daylight ? 0.6 - sin(solar * .pi) * 0.5 : 0.09),
            width: 64, height: 64)
        context.fill(Path(ellipseIn: orb.insetBy(dx: -22, dy: -22)), with: .radialGradient(
            Gradient(colors: [Color.yellow.opacity(profile.daylight ? 0.24 : 0.06), .clear]),
            center: CGPoint(x: orb.midX, y: orb.midY), startRadius: 25, endRadius: 60))
        var orbContext = context
        var disc = Path(ellipseIn: orb)
        if !profile.daylight {
            orbContext.clip(to: Path(ellipseIn: orb))
            disc.addEllipse(in: orb.offsetBy(dx: 18, dy: -10))
        }
        orbContext.fill(disc, with: .color(profile.daylight ? .yellow.opacity(0.65) : .white.opacity(0.75)),
                     style: FillStyle(eoFill: true))
        for index in 0..<8 {
            let width = 150 + seed(index, 8) * 210
            let drift = time * (2 + profile.wind * 0.6) * profile.windSign
            let span = size.width + width
            let x = (seed(index, 6) * span + drift).truncatingRemainder(dividingBy: span)
            let wrappedX = x < 0 ? x + span : x
            let y = size.height * (0.08 + seed(index, 7) * 0.38) + sin(time * 0.25 + Double(index)) * 6
            let rect = CGRect(x: wrappedX - width, y: y, width: width, height: width * 0.25)
            var cloud = Path()
            cloud.addEllipse(in: rect)
            cloud.addEllipse(in: CGRect(x: rect.minX + width * 0.15, y: y - width * 0.1, width: width * 0.4, height: width * 0.3))
            cloud.addEllipse(in: CGRect(x: rect.minX + width * 0.4, y: y - width * 0.16, width: width * 0.45, height: width * 0.38))
            context.fill(cloud, with: .color(.white.opacity((0.05 + profile.cloudCover * 0.16) * (profile.daylight ? 1 : 0.6))))
        }
    }
    private func drawWeather(context: inout GraphicsContext, size: CGSize, profile: OmnibarWeatherSnapshot,
                             time: Double, compact: Bool) {
        // Clip each control separately so overlapping rectangles never expose text.
        for surface in surfaces where !surface.isEmpty {
            var exposed = Path(CGRect(origin: .zero, size: size))
            exposed.addRect(surface)
            context.clip(to: exposed, style: FillStyle(eoFill: true))
        }
        let snow = profile.isSnowing && !profile.isRaining
        let count = compact ? 40 : snow ? 90 : 150
        let bins = 24
        var deposits = surfaces.map { _ in Array(repeating: 0.0, count: bins + 1) }
        if profile.isRaining || profile.isSnowing {
            for index in 0..<count {
                let speed = snow ? 44 + seed(index, 3) * 34 : 440 + seed(index, 3) * 220
                let wind = profile.windSign * min(80, profile.wind * (snow ? 4 : 3))
                let margin = abs(wind) * (size.height / speed + 1) + 24
                let particle = OmnibarWeatherParticle(
                    originX: seed(index, 15) * (size.width + 2 * margin) - margin,
                    terminalSpeed: speed, responseTime: snow ? 0.65 : 0.14,
                    wind: wind, sway: snow ? 12 : 0, phase: Double(index))
                let landing = particle.landing(in: size, surfaces: surfaces)
                let period = particle.fallTime(to: size.height + 24) + (snow ? 0.8 : 0.35)
                let delay = seed(index, 12) * period
                let elapsed = time - delay
                guard elapsed >= 0 else { continue }
                let age = elapsed.truncatingRemainder(dividingBy: period)
                if let surface = landing.surface {
                    let rect = surfaces[surface]
                    let bin = min(bins, max(0, Int((landing.point.x - rect.minX - 14) / (rect.width - 28) * Double(bins))))
                    let impacts = OmnibarWeatherParticle.impactCount(time: time, delay: delay,
                                                                   flight: landing.time, period: period)
                    if snow {
                        deposits[surface][bin] += Double(impacts) * 0.22 * 90 / Double(count)
                    } else if impacts > 0 {
                        // Water drains instead of growing into a snow-like bank.
                        let sinceImpact = elapsed - landing.time - Double(impacts - 1) * period
                        deposits[surface][bin] += exp(-sinceImpact / 1.2) * 0.8
                    }
                }
                if age < landing.time {
                    let point = particle.position(at: age)
                    if snow {
                        let radius = 1.5 + seed(index, 5) * 2
                        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                           width: radius * 2, height: radius * 2)),
                                     with: .color(.white.opacity(0.45 + seed(index, 9) * 0.4)))
                    } else {
                        var drop = Path()
                        drop.move(to: particle.position(at: max(0, age - 0.025)))
                        drop.addLine(to: point)
                        context.stroke(drop, with: .color(.cyan.opacity(0.4)),
                                       style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    }
                } else if !snow && age - landing.time < 0.35 {
                    let splashAge = age - landing.time
                    for direction in [-1.0, 1.0] {
                        let x = landing.point.x + (direction * 24 + wind * 0.15) * splashAge
                        let y = landing.point.y - 34 * splashAge + 100 * splashAge * splashAge
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                                     with: .color(.white.opacity((1 - splashAge / 0.35) * 0.5)))
                    }
                }
            }
        }
        for (index, rect) in surfaces.enumerated() where rect.width > 40 && rect.minY > 0 {
            var bank = Path()
            bank.move(to: CGPoint(x: rect.minX + 14, y: rect.minY))
            for step in 0...bins {
                let x = rect.minX + 14 + (rect.width - 28) * Double(step) / Double(bins)
                let sheltered = surfaces.contains { $0.minY < rect.minY && $0.maxY > 0 && x >= $0.minX && x <= $0.maxX }
                let nearby = deposits[index][max(0, step - 1)...min(bins, step + 1)].reduce(0, +) / 3
                let historical = sheltered ? 0 : profile.snowDepth * min(1, time / 3)
                let depth = snow || profile.snowDepth > 0
                    ? min(14, historical + min(4, nearby)) : min(1.5, nearby)
                let taper = min(1, Double(min(step, bins - step)) / 2)
                let height = depth * taper * (0.85 + 0.15 * sin(Double(step) * 0.65))
                bank.addLine(to: CGPoint(x: x, y: rect.minY - height))
            }
            bank.addLine(to: CGPoint(x: rect.maxX - 14, y: rect.minY)); bank.closeSubpath()
            context.fill(bank, with: .color(snow || profile.snowDepth > 0 ? .white.opacity(0.85) : .cyan.opacity(0.45)))
        }
        if max(profile.wind, profile.recentWind) >= 4 {
            for index in 0..<(compact ? 4 : 9) {
                let elapsed = time * 0.12 - seed(index, 24)
                guard elapsed >= 0 else { continue }
                let phase = elapsed.truncatingRemainder(dividingBy: 1)
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
                let elapsed = time * (0.06 + seed(index, 33) * 0.06) - seed(index, 31)
                guard elapsed >= 0 else { continue }
                let phase = elapsed.truncatingRemainder(dividingBy: 1)
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

/// Gravity with linear air drag approaches terminal speed; wind and flutter
/// share the same trajectory used to find the first top-edge collision.
nonisolated struct OmnibarWeatherParticle {
    let originX: Double
    let terminalSpeed: Double
    let responseTime: Double
    let wind: Double
    var sway = 0.0
    var phase = 0.0

    func position(at time: Double) -> CGPoint {
        let t = max(0, time)
        let travel = t - responseTime * (1 - exp(-t / responseTime))
        return CGPoint(x: originX + wind * travel + sway * (sin(t * 1.3 + phase) - sin(phase)),
                       y: -24 + terminalSpeed * travel)
    }

    func fallTime(to y: Double) -> Double {
        let distance = max(0, y + 24) / terminalSpeed
        guard distance > 0 else { return 0 }
        var t = distance + responseTime
        for _ in 0..<6 {
            let drag = exp(-t / responseTime)
            t -= (t - responseTime * (1 - drag) - distance) / max(0.0001, 1 - drag)
        }
        return max(0, t)
    }

    func landing(in size: CGSize, surfaces: [CGRect]) -> (time: Double, point: CGPoint, surface: Int?) {
        // shortcut: only registered browser controls collide; add page geometry for webpage elements.
        var time = fallTime(to: size.height)
        var surface: Int?
        for (index, rect) in surfaces.enumerated() where !rect.isEmpty && rect.minY > 0 {
            let candidate = fallTime(to: rect.minY)
            let x = position(at: candidate).x
            // Rounded corners shed precipitation rather than supporting a bank.
            if candidate < time && x >= rect.minX + 14 && x <= rect.maxX - 14 {
                time = candidate
                surface = index
            }
        }
        return (time, position(at: time), surface)
    }

    static func impactCount(time: Double, delay: Double, flight: Double, period: Double) -> Int {
        guard time >= delay + flight else { return 0 }
        return Int(floor((time - delay - flight) / period)) + 1
    }
}
