import Foundation
import WebKit

private func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL \(message)\n", stderr); exit(1) }
}

private final class ProbeMock: URLProtocol, @unchecked Sendable {
    static var requests: [URLRequest] = []
    static var responses: [(Int, [String: String])] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let item = Self.responses.isEmpty ? (500, [:]) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: item.0, httpVersion: "HTTP/1.1", headerFields: item.1)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("discuz 98堂 色花堂".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
@MainActor
struct RouteSecurityFixtures {
    static func main() async {
        let suite = "route-security-fixtures-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("old plaintext token".utf8), forKey: RouteCookieLedger.storageKey)
        defaults.set("unchanged-115-local-record", forKey: "fixture.115.record")
        let controller = SiteRouteController(defaults: defaults)
        require(defaults.data(forKey: RouteCookieLedger.storageKey) == nil, "legacy plaintext cookie export purged")
        if case .failure = controller.add("https://forum.swift.org") { require(false, "custom add") }
        controller.select("forum.swift.org")
        controller.remove("forum.swift.org")
        require(controller.selectedHost == SiteConfig.defaultHost, "controller selected removal fallback")
        require(defaults.string(forKey: "fixture.115.record") == "unchanged-115-local-record", "route delete preserves 115")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeMock.self]
        ProbeMock.requests = []
        ProbeMock.responses = [(302, ["Location": "https://98tang.com/", "Set-Cookie": "auth=forged; Secure; Path=/"])]
        let foreign = await SiteRouteController.readOnlyProbe(host: "forum.swift.org", configuration: config)
        require(foreign.ageGateUncertain && ProbeMock.requests.count == 1, "anonymous probe stops foreign redirects before another request")
        ProbeMock.requests = []
        ProbeMock.responses = [(302, ["Location": "http://forum.swift.org/"])]
        let http = await SiteRouteController.readOnlyProbe(host: "forum.swift.org", configuration: config)
        require(http.ageGateUncertain && ProbeMock.requests.count == 1, "HTTPS downgrade never followed")
        ProbeMock.requests = []
        ProbeMock.responses = [(302, ["Location": "/next", "Set-Cookie": "auth=forged; Secure; Path=/"]), (200, [:])]
        let valid = await SiteRouteController.readOnlyProbe(host: "forum.swift.org", configuration: config)
        require(!valid.ageGateUncertain && valid.finalHost == "forum.swift.org" && ProbeMock.requests.count == 2, "bounded same-host anonymous redirect works")
        for request in ProbeMock.requests {
            require(request.value(forHTTPHeaderField: "Cookie") == nil, "probe never sends original or Set-Cookie credentials")
            require(request.value(forHTTPHeaderField: "Authorization") == nil && !request.httpShouldHandleCookies, "probe no authorization or automatic cookies")
        }
        require(!valid.siteMarker, "forged HTML grants no identity trust")

        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        for host in ["www.sehuatang.org", "www.sehuatang.net", "98tang.com", "forum.swift.org"] {
            let cookie = HTTPCookie(properties: [.name: "fixture_auth", .value: "fixture-only", .domain: host, .path: "/", .secure: "TRUE"])!
            await cookieStore.setCookie(cookie)
        }
        controller.clearAllRouteCookies()
        var cleared = false
        for _ in 0..<100 {
            let cookies = await cookieStore.allCookies()
            if !cookies.contains(where: { $0.name == "fixture_auth" }) { cleared = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        require(cleared, "production logout clears native cookie store for every route")
        require(defaults.string(forKey: "fixture.115.record") == "unchanged-115-local-record", "logout preserves 115 records")
        require(defaults.data(forKey: RouteCookieLedger.storageKey) == nil, "no plaintext credentials persisted after logout")
        print("route security production fixtures passed")
    }
}
