//
//  WindowLayoutTests.swift
//  Straight Up BrowserTests
//

import Testing
import AppKit
@testable import Browser

@MainActor
struct WindowLayoutTests {
    // A 1600×1000 screen sitting below a menu bar, origin off zero to catch
    // anyone who forgets the screen doesn't start at (0, 0).
    let screen = NSRect(x: 100, y: 50, width: 1600, height: 1000)

    @Test func fullWidthIgnoresPosition() {
        for position in WindowLayout.positions {
            #expect(WindowLayout.frame(in: screen, width: "full", position: position.id) == screen)
        }
    }

    @Test func widthIsAMultipleOfHeight() {
        let half = WindowLayout.frame(in: screen, width: "half", position: "left")
        #expect(half.width == 500)
        #expect(half.height == 1000)
    }

    @Test func positionSlidesAcrossTheLeftoverSpace() {
        #expect(WindowLayout.frame(in: screen, width: "half", position: "left").minX == screen.minX)
        #expect(WindowLayout.frame(in: screen, width: "half", position: "center").midX == screen.midX)
        #expect(WindowLayout.frame(in: screen, width: "half", position: "right").maxX == screen.maxX)
    }

    @Test func everyOptionStaysOnScreen() {
        for width in WindowLayout.widths {
            for position in WindowLayout.positions {
                let frame = WindowLayout.frame(in: screen, width: width.id, position: position.id)
                #expect(screen.contains(frame), "\(width.id)/\(position.id) escaped the screen")
            }
        }
    }

    @Test func unknownIDsFallBackToFullAndCentered() {
        #expect(WindowLayout.frame(in: screen, width: "bogus", position: "bogus") == screen)
    }

    // A tall screen can't fit a width of 3/4 its height — clamp, don't overflow.
    @Test func widthClampsToScreenWidth() {
        let tall = NSRect(x: 0, y: 0, width: 1000, height: 1600)
        let frame = WindowLayout.frame(in: tall, width: "threeQuarters", position: "right")
        #expect(frame.width == 1000)
        #expect(frame.minX == 0)
    }

    @Test func leftRightSnapKeepFullHeightAndPinAnEdge() {
        let left = WindowLayout.snapFrame(in: screen, direction: .left, ratio: 0.5)
        #expect(left.minX == screen.minX)
        #expect(left.width == 800)
        #expect(left.height == screen.height)

        let right = WindowLayout.snapFrame(in: screen, direction: .right, ratio: 0.5)
        #expect(right.maxX == screen.maxX)
        #expect(right.width == 800)
        #expect(right.height == screen.height)
    }

    @Test func topBottomSnapKeepFullWidthAndPinAnEdge() {
        let top = WindowLayout.snapFrame(in: screen, direction: .top, ratio: 0.5)
        #expect(top.maxY == screen.maxY)
        #expect(top.height == 500)
        #expect(top.width == screen.width)

        let bottom = WindowLayout.snapFrame(in: screen, direction: .bottom, ratio: 0.5)
        #expect(bottom.minY == screen.minY)
        #expect(bottom.height == 500)
        #expect(bottom.width == screen.width)
    }

    @Test func everySnapRatioStaysOnScreen() {
        for direction: WindowLayout.SnapDirection in [.left, .right, .top, .bottom] {
            for ratio in WindowLayout.snapRatios {
                let frame = WindowLayout.snapFrame(in: screen, direction: direction, ratio: ratio)
                #expect(screen.contains(frame), "\(direction)/\(ratio) escaped the screen")
            }
        }
    }

    @Test func verticalCyclesKeepLegacyHeightsThenUseFullHeightCenteredWidths() {
        for direction: WindowLayout.SnapDirection in [.top, .bottom] {
            let cycle = WindowPlacementPolicy.cycle(for: direction)
            var current = NSRect(x: 127, y: 83, width: 907, height: 719)
            for preset in cycle + [cycle[0]] {
                let expected = WindowPlacementPolicy.frame(for: preset, in: screen, scale: 2)
                current = WindowPlacementPolicy.nextFrame(from: current, direction: direction, in: screen, scale: 2)!
                #expect(current == expected)
                if case .centered = preset { #expect(current.height == screen.height) }
            }
        }
    }

    @Test func oppositeDirectionRestartsAtItsOwnEdgeButCenteredStatesAreShared() {
        for source: WindowLayout.SnapDirection in [.top, .bottom] {
            let other: WindowLayout.SnapDirection = source == .top ? .bottom : .top
            for index in 0..<3 {
                let current = WindowPlacementPolicy.frame(for: .edge(source, index), in: screen, scale: 2)
                let next = WindowPlacementPolicy.nextFrame(from: current, direction: other, in: screen, scale: 2)
                #expect(next == WindowPlacementPolicy.frame(for: .edge(other, 0), in: screen, scale: 2))
            }
            for index in 0..<3 {
                let current = WindowPlacementPolicy.frame(for: .centered(index), in: screen, scale: 2)
                let expected: WindowPlacementPolicy.Preset = index < 2 ? .centered(index + 1) : .edge(other, 0)
                #expect(WindowPlacementPolicy.nextFrame(from: current, direction: other, in: screen, scale: 2)
                        == WindowPlacementPolicy.frame(for: expected, in: screen, scale: 2))
            }
        }
    }

    @Test func centeredGeometryUsesWidthFractionsAndNegativeScreenOrigins() {
        let regular = NSRect(x: 0, y: 0, width: 1_200, height: 900)
        for (index, expected) in [NSRect(x: 300, y: 0, width: 600, height: 900),
                                  NSRect(x: 400, y: 0, width: 400, height: 900),
                                  NSRect(x: 450, y: 0, width: 300, height: 900)].enumerated() {
            #expect(WindowPlacementPolicy.frame(for: .centered(index), in: regular, scale: 1) == expected)
        }
        let negative = NSRect(x: -1_920, y: 40, width: 1_920, height: 1_040)
        #expect(WindowPlacementPolicy.frame(for: .centered(0), in: negative, scale: 2)
                == NSRect(x: -1_440, y: 40, width: 960, height: 1_040))
    }

    @Test func oddDimensionsStayPixelAlignedAndHalvesShareOneEdge() {
        let visible = NSRect(x: -19.5, y: 20.5, width: 1_201, height: 901)
        for scale: CGFloat in [1, 2] {
            for direction: WindowLayout.SnapDirection in [.top, .bottom] {
                for preset in WindowPlacementPolicy.cycle(for: direction) {
                    let frame = WindowPlacementPolicy.frame(for: preset, in: visible, scale: scale)
                    #expect(visible.contains(frame))
                    for edge in [frame.minX, frame.maxX, frame.minY, frame.maxY] {
                        #expect(abs(edge * scale - (edge * scale).rounded()) < 0.000_001)
                    }
                }
            }
            let top = WindowPlacementPolicy.frame(for: .edge(.top, 0), in: visible, scale: scale)
            let bottom = WindowPlacementPolicy.frame(for: .edge(.bottom, 0), in: visible, scale: scale)
            #expect(top.minY == bottom.maxY)
        }
    }

    @Test func constraintsSkipUnavailableStatesWithoutClampingTheirMeaning() {
        let visible = NSRect(x: 0, y: 0, width: 1_200, height: 900)
        let thirds = WindowPlacementPolicy.frame(for: .centered(1), in: visible, scale: 2)
        let minimumWidth = WindowPlacementPolicy.Constraints(minimum: CGSize(width: 350, height: 0))
        #expect(WindowPlacementPolicy.nextFrame(from: thirds, direction: .top, in: visible, scale: 2, constraints: minimumWidth)
                == WindowPlacementPolicy.frame(for: .edge(.top, 0), in: visible, scale: 2))
        let minimumHeight = WindowPlacementPolicy.Constraints(minimum: CGSize(width: 0, height: 400))
        let half = WindowPlacementPolicy.frame(for: .edge(.bottom, 0), in: visible, scale: 2)
        #expect(WindowPlacementPolicy.nextFrame(from: half, direction: .bottom, in: visible, scale: 2, constraints: minimumHeight)
                == WindowPlacementPolicy.frame(for: .edge(.bottom, 2), in: visible, scale: 2))
        let impossible = WindowPlacementPolicy.Constraints(minimum: CGSize(width: 1_300, height: 1_000))
        #expect(WindowPlacementPolicy.nextFrame(from: half, direction: .top, in: visible, scale: 2, constraints: impossible) == nil)
    }

    @Test func singleFeasiblePresetAndChangedGeometryDoNotUseAStaleIndex() {
        let visible = NSRect(x: 0, y: 0, width: 1_200, height: 900)
        let constraints = WindowPlacementPolicy.Constraints(minimum: CGSize(width: 599, height: 899),
                                                            maximum: CGSize(width: 601, height: 901))
        let current = WindowPlacementPolicy.frame(for: .centered(0), in: visible, scale: 2)
        #expect(WindowPlacementPolicy.nextFrame(from: current, direction: .top, in: visible, scale: 2, constraints: constraints) == current)
        let changed = current.offsetBy(dx: 27, dy: 10)
        #expect(WindowPlacementPolicy.nextFrame(from: changed, direction: .bottom, in: visible, scale: 2)
                == WindowPlacementPolicy.frame(for: .edge(.bottom, 0), in: visible, scale: 2))
    }

    @Test func missingWindowScreenUsesIntersectionThenNearestWithStableTies() {
        let screens = [NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
                       NSRect(x: 0, y: 0, width: 1_200, height: 900)]
        #expect(WindowPlacementPolicy.fallbackScreenIndex(window: NSRect(x: -1_000, y: 20, width: 1_100, height: 800), screens: screens) == 0)
        #expect(WindowPlacementPolicy.fallbackScreenIndex(window: NSRect(x: 3_000, y: 10, width: 100, height: 100), screens: screens) == 1)
        #expect(WindowPlacementPolicy.fallbackScreenIndex(window: .zero, screens: []) == nil)
        #expect(WindowPlacementPolicy.fallbackScreenIndex(window: .zero, screens: [screens[0], screens[0]]) == 0)
    }

    @Test func constraintsUseContentAspectAndIncrementsAndFrameMaximums() {
        let wide = NSRect(x: 0, y: 0, width: 1_600, height: 922)
        let constraints = WindowPlacementPolicy.Constraints(maximum: CGSize(width: 1_600, height: 922),
            aspectRatio: CGSize(width: 16, height: 9), resizeIncrements: CGSize(width: 10, height: 10),
            contentInset: CGSize(width: 0, height: 22))
        #expect(WindowPlacementPolicy.isFeasible(wide, constraints: constraints, scale: 2))
        #expect(!WindowPlacementPolicy.isFeasible(wide.insetBy(dx: 1, dy: 0), constraints: constraints, scale: 2))
        #expect(!WindowPlacementPolicy.isFeasible(NSRect(x: 0, y: 0, width: 1_601, height: 922), constraints: constraints, scale: 2))
    }
}
