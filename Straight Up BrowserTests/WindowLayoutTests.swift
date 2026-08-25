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
}
