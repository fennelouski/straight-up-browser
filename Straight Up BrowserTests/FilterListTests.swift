//
//  FilterListTests.swift
//  Straight Up BrowserTests
//
//  The EasyList download is untrusted input on its way into WebKit's rule
//  compiler. This is the gate it has to pass.
//

import Testing
import WebKit
@testable import Browser

struct FilterListTests {

    private func ruleListData(count: Int) -> Data {
        let rule = #"{"trigger":{"url-filter":"^https?://ads\\.example\#(count)\\.com"},"action":{"type":"block"}}"#
        return Data("[\((0..<count).map { _ in rule }.joined(separator: ","))]".utf8)
    }

    @Test func acceptsARealFilterList() throws {
        let data = ruleListData(count: 2_000)
        #expect(data.count > 100_000)
        #expect(WebViewManager.validatedFilterList(data) != nil)
    }

    @Test func rejectsWhatIsNotOne() {
        // An error page or redirect served with a 200.
        #expect(WebViewManager.validatedFilterList(Data(String(repeating: "<html>404</html>", count: 20_000).utf8)) == nil)
        // A truncated download.
        #expect(WebViewManager.validatedFilterList(Data("[{\"trigger\":{}}]".utf8)) == nil)
        // Big and valid JSON, but not a rule array.
        #expect(WebViewManager.validatedFilterList(Data("{\"rules\":\(String(repeating: "x", count: 200_000))}".utf8)) == nil)
        #expect(WebViewManager.validatedFilterList(Data()) == nil)
    }
}
