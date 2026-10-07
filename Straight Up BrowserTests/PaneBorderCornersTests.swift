import SwiftUI
import Testing
@testable import Browser

struct PaneBorderCornersTests {
    private let window = CGRect(x: 40, y: 60, width: 1000, height: 800)
    private let radius: CGFloat = 10

    private func corners(_ pane: CGRect, radius: CGFloat = 10) -> PaneBorderCorners {
        PaneBorderCorners.matching(pane: pane, window: window, radius: radius)
    }

    @Test func columnLayoutsRoundOnlyTheirOuterCorners() {
        // Equal and resized columns for each supported column count.
        for fractions: [CGFloat] in [[0.5, 0.5], [0.23, 0.77],
                                    [0.333, 0.333, 0.334], [0.2, 0.55, 0.25]] {
            var x = window.minX
            for (index, fraction) in fractions.enumerated() {
                let pane = CGRect(x: x, y: window.minY,
                                  width: window.width * fraction, height: window.height)
                let actual = corners(pane)
                #expect(actual.topLeft == (index == 0 ? radius : 0))
                #expect(actual.bottomLeft == (index == 0 ? radius : 0))
                #expect(actual.topRight == (index == fractions.count - 1 ? radius : 0))
                #expect(actual.bottomRight == (index == fractions.count - 1 ? radius : 0))
                x += pane.width
            }
        }
    }

    @Test func fourPaneGridRoundsOneCornerPerPane() {
        for column: CGFloat in [0.5, 0.27, 0.81] {
            for row: CGFloat in [0.5, 0.18, 0.73] {
                let splitX = window.minX + window.width * column
                let splitY = window.minY + window.height * row
                let topLeft = CGRect(x: window.minX, y: splitY,
                                     width: splitX - window.minX, height: window.maxY - splitY)
                let topRight = CGRect(x: splitX, y: splitY,
                                      width: window.maxX - splitX, height: window.maxY - splitY)
                let bottomLeft = CGRect(x: window.minX, y: window.minY,
                                        width: splitX - window.minX, height: splitY - window.minY)
                let bottomRight = CGRect(x: splitX, y: window.minY,
                                         width: window.maxX - splitX, height: splitY - window.minY)
                #expect(corners(topLeft) == PaneBorderCorners(topLeft: radius))
                #expect(corners(topRight) == PaneBorderCorners(topRight: radius))
                #expect(corners(bottomLeft) == PaneBorderCorners(bottomLeft: radius))
                #expect(corners(bottomRight) == PaneBorderCorners(bottomRight: radius))
            }
        }
    }

    @Test func chromeEdgesAreSquareEvenAtTheEdgeOfThePaneContainer() {
        let besideLeftTools = CGRect(x: window.minX + 300, y: window.minY, width: 700, height: 800)
        #expect(corners(besideLeftTools) == PaneBorderCorners(topRight: radius, bottomRight: radius))
        let aboveBottomTools = CGRect(x: window.minX, y: window.minY + 250, width: 1000, height: 550)
        #expect(corners(aboveBottomTools) == PaneBorderCorners(topLeft: radius, topRight: radius))
        let interior = window.insetBy(dx: 100, dy: 100)
        #expect(corners(interior) == PaneBorderCorners())
    }

    @Test func squareWindowsAndSinglePaneGeometry() {
        #expect(corners(window) == PaneBorderCorners(topLeft: radius, topRight: radius,
                                                    bottomLeft: radius, bottomRight: radius))
        #expect(corners(window, radius: 0) == PaneBorderCorners())
    }

    @Test func strokeUsesAppKitCornerOrientationAndStaysInsideThePane() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let path = PaneBorderCorners(topLeft: radius).path(in: bounds, lineWidth: 2)
        #expect(bounds.contains(path.boundingRect))
        // The inset bottom-left join is square; the top-left is curved inward.
        #expect(path.contains(CGPoint(x: 1.1, y: 1.1)))
        #expect(!path.contains(CGPoint(x: 1.1, y: 198.9)))
        #expect(path.contains(CGPoint(x: 298.9, y: 198.9)))
    }
}
