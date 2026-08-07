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
}
