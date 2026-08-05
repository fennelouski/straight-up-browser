//
//  SignedInSitesTests.swift
//  Straight Up BrowserTests
//

import Testing
import Foundation
@testable import Browser

struct SignedInSitesTests {

    private func cookie(_ name: String, domain: String, httpOnly: Bool) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: "x",
            .domain: domain,
            .path: "/"
        ]
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    @Test func onlyServerSetAuthCookiesCount() {
        // Auth-looking but readable by JS — an analytics cookie, not a session.
        #expect(!SignedInSites.looksLikeLogin(cookie("session_id", domain: "a.com", httpOnly: false)))
        // Server-set but not auth-shaped.
        #expect(!SignedInSites.looksLikeLogin(cookie("theme", domain: "a.com", httpOnly: true)))
        #expect(SignedInSites.looksLikeLogin(cookie("PHPSESSID", domain: "a.com", httpOnly: true)))
        #expect(SignedInSites.looksLikeLogin(cookie("Auth-Token", domain: "a.com", httpOnly: true)))
    }

    @Test func hostsAreLeadingDotStrippedAndDeduped() {
        let hosts = SignedInSites.hosts(in: [
            cookie("sessionid", domain: ".github.com", httpOnly: true),
            cookie("user_session", domain: "github.com", httpOnly: true),
            cookie("pixel", domain: "ads.example", httpOnly: true),
            cookie("auth", domain: "bank.example", httpOnly: false)
        ])
        #expect(hosts == ["github.com"])
    }
}
