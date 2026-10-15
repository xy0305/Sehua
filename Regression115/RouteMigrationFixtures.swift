import Foundation

private func require(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}

@main
enum RouteMigrationFixtures {
    static func main() {
        rejectParsing()
        acceptBuiltins()
        persistWithoutSecrets()
        directOrgMigration()
        verifiedFamilyMigration()
        rejectCrossSiteAndChallenge()
        logoutClearsEveryScope()
        redirectVerification()
        fputs("route migration fixtures passed\n", stdout)
    }

    static func rejectParsing() {
        let rejected = [
            "http://www.sehuatang.org",
            "https://user:pass@www.sehuatang.org",
            "https://www.sehuatang.org:8443",
            "https://1.2.3.4",
            "https://127.0.0.1",
            "https://evil.example",
            "https://www.sehuatang.org.evil.com",
            "www.sehuatang.org/forum.php",
            "https://www.sehuatang.org/path",
            "ftp://www.sehuatang.org",
            "sehuatang.net",
            "www.98tang.com",
            ""
        ]
        for raw in rejected {
            guard case .failure = SiteRoutePolicy.normalize(raw) else {
                require(false, "expected rejection for \(raw)")
                return
            }
        }
        require(SiteRoutePolicy.isIPAddress("192.168.1.1"), "dotted IP")
        require(!SiteRoutePolicy.isIPAddress("www.sehuatang.org"), "hostname is not an IP")
    }

    static func acceptBuiltins() {
        for host in SiteRoutePolicy.builtinHosts {
            guard case .success(let normalized) = SiteRoutePolicy.normalize("HTTPS://\(host.uppercased())/") else {
                require(false, "builtin accepted \(host)")
                return
            }
            require(normalized == host, "lowercase host \(host) got \(normalized)")
        }
        guard case .success(let spaced) = SiteRoutePolicy.normalize("  www.sehuatang.net  ") else {
            require(false, "trimmed host")
            return
        }
        require(spaced == "www.sehuatang.net", "trim")
    }

    static func persistWithoutSecrets() {
        let added = SiteRouteStore.fresh().adding("https://user:secret@www.sehuatang.net")
        require(added.failureReason != nil, "userinfo must not be stored")
        var store = SiteRouteStore.fresh().adding("www.sehuatang.net").value
        store = store.settingEnabled("98tang.com", false)
        store = store.removing("www.sehuatang.org")
        require(store.routes.contains { $0.host == "www.sehuatang.org" && $0.builtin }, "builtin cannot be deleted")
        let removed = store.removing("www.sehuatang.net")
        require(!removed.routes.contains { $0.host == "www.sehuatang.net" }, "manual route removed")
        let json = String(data: store.persistedJSON(), encoding: .utf8) ?? ""
        require(!json.contains("secret"), "route config has no secret")
        require(!json.contains("cookie"), "route config has no cookie")
        require(!json.contains("password"), "route config has no password")
        let loaded = SiteRouteStore.load(data: store.persistedJSON(), legacyHost: "http://evil.example")
        require(loaded.routes.map(\.host).starts(with: SiteRoutePolicy.builtinHosts), "builtins restored")
        require(loaded.routes.first { $0.host == "98tang.com" }?.enabled == false, "disabled flag persists")
    }

    static func directOrgMigration() {
        require(SiteRoutePolicy.sameSiteDirect("www.sehuatang.org", "sehuatang.org"), "org pair")
        require(!SiteRoutePolicy.requiresReadOnlyVerification("sehuatang.org", "www.sehuatang.org"), "direct pair skips probe")
        let decision = RouteMigration.decision(
            source: "www.sehuatang.org", target: "sehuatang.org", hasCookies: true, probe: nil)
        require(decision == .direct, "org migrates without probe")
        var ledger = RouteCookieLedger(scopes: [
            "www.sehuatang.org": [ScopedCookie(name: "cPNj_2132_auth", value: "token", path: "/", secure: true, expires: nil)]
        ])
        ledger = ledger.migrating(from: "www.sehuatang.org", to: "sehuatang.org")!
        require(ledger.scopes["sehuatang.org"]?.first?.value == "token", "cookie adapted to bare org")
        require(ledger.scopes["sehuatang.org"]?.first?.secure == true, "adapted cookie stays secure")
    }

    static func verifiedFamilyMigration() {
        require(SiteRoutePolicy.requiresReadOnlyVerification("www.sehuatang.org", "www.sehuatang.net"), "net needs probe")
        require(SiteRoutePolicy.requiresReadOnlyVerification("sehuatang.org", "98tang.com"), "98tang needs probe")
        let probe = RouteMigration.Probe(
            finalHost: "www.sehuatang.net", challenged: false, ageGateUncertain: false, siteMarker: true, redirects: 1)
        let decision = RouteMigration.decision(
            source: "www.sehuatang.org", target: "www.sehuatang.net", hasCookies: true, probe: probe)
        require(decision == .verified, "verified family migrates")
        let ledger = RouteCookieLedger(scopes: [
            "www.sehuatang.org": [ScopedCookie(name: "cPNj_2132_auth", value: "token", path: "/", secure: true, expires: nil)]
        ]).migrating(from: "www.sehuatang.org", to: "www.sehuatang.net")
        require(ledger?.scopes["www.sehuatang.net"]?.first?.name == "cPNj_2132_auth", "cookie copied only after verification")
        require(RouteCookieLedger(scopes: ["www.sehuatang.org": []]).migrating(from: "www.sehuatang.org", to: "evil.example") == nil, "cross-site adapt refused")
    }

    static func rejectCrossSiteAndChallenge() {
        let foreign = RouteMigration.Probe(
            finalHost: "evil.example", challenged: false, ageGateUncertain: false, siteMarker: false, redirects: 1)
        require(
            RouteMigration.decision(source: "www.sehuatang.org", target: "www.sehuatang.net", hasCookies: true, probe: foreign)
                == .rejected("最终跳转不属于已确认同站点，未发送原登录 Cookie"),
            "foreign final host")
        let cf = RouteMigration.Probe(
            finalHost: "www.sehuatang.net", challenged: true, ageGateUncertain: false, siteMarker: false, redirects: 0)
        require(
            RouteMigration.decision(source: "www.sehuatang.org", target: "98tang.com", hasCookies: true, probe: cf)
                == .rejected("验证遇到 Cloudflare/挑战页，未发送原登录 Cookie"),
            "cf")
        let age = RouteMigration.Probe(
            finalHost: "98tang.com", challenged: false, ageGateUncertain: true, siteMarker: true, redirects: 0)
        require(
            RouteMigration.decision(source: "www.sehuatang.org", target: "98tang.com", hasCookies: true, probe: age)
                == .rejected("年龄门结果不确定，未发送原登录 Cookie"),
            "age gate")
        require(
            RouteMigration.decision(source: "www.sehuatang.org", target: "evil.example", hasCookies: true, probe: nil)
                == .rejected("目标不是已确认站点，未发送原登录 Cookie"),
            "cross site")
        let untouched = RouteCookieLedger(scopes: [
            "www.sehuatang.org": [ScopedCookie(name: "a", value: "b", path: "/", secure: true, expires: nil)]
        ])
        require(untouched.migrating(from: "www.sehuatang.org", to: "evil.example") == nil, "rejection does not copy")
        require(untouched.scopes["www.sehuatang.org"]?.count == 1, "source cookies remain until logout")
    }

    static func logoutClearsEveryScope() {
        let ledger = RouteCookieLedger(scopes: [
            "www.sehuatang.org": [ScopedCookie(name: "a", value: "1", path: "/", secure: true, expires: nil)],
            "www.sehuatang.net": [ScopedCookie(name: "a", value: "2", path: "/", secure: true, expires: nil)],
            "98tang.com": [ScopedCookie(name: "a", value: "3", path: "/", secure: true, expires: nil)]
        ]).clearingAll()
        require(ledger.scopes.isEmpty, "logout clears every route cookie")
        let text = String(data: ledger.persistedJSON(), encoding: .utf8) ?? ""
        require(!text.contains("sehuatang"), "persisted logout has no host cookie")
    }

    static func redirectVerification() {
        let ok = RouteMigration.probe(
            startHost: "www.sehuatang.net",
            steps: [RouteRedirectStep(status: 302, location: "https://www.sehuatang.net/forum.php?mod=forumdisplay&fid=2")],
            bodyHost: "www.sehuatang.net",
            body: "<html><a href='forum.php'>discuz 色花堂</a></html>")
        require(ok.siteMarker && !ok.challenged && ok.finalHost == "www.sehuatang.net", "confirmed redirect")
        let http = RouteMigration.probe(
            startHost: "www.sehuatang.net",
            steps: [RouteRedirectStep(status: 301, location: "http://www.sehuatang.net/")],
            bodyHost: "www.sehuatang.net",
            body: "discuz")
        require(http.ageGateUncertain, "non-HTTPS redirect is uncertain")
        let tooMany = (0..<6).map { _ in RouteRedirectStep(status: 302, location: "https://www.sehuatang.net/next") }
        let bounded = RouteMigration.probe(
            startHost: "www.sehuatang.net", steps: tooMany, bodyHost: "www.sehuatang.net", body: "discuz")
        require(bounded.redirects <= RouteMigration.maxRedirects, "redirect cap")
        let cf = RouteMigration.probe(
            startHost: "98tang.com", steps: [], bodyHost: "98tang.com", body: "Just a moment cf-challenge")
        require(cf.challenged && !cf.siteMarker, "challenge is not a site marker")
        let age = RouteMigration.probe(
            startHost: "98tang.com", steps: [], bodyHost: "98tang.com", body: "<a class='enter-btn'>满18岁</a>")
        require(age.ageGateUncertain && !age.siteMarker, "age gate without marker is uncertain")
        let userinfo = RouteMigration.probe(
            startHost: "www.sehuatang.net",
            steps: [RouteRedirectStep(status: 302, location: "https://user:pass@www.sehuatang.net/")],
            bodyHost: "www.sehuatang.net",
            body: "discuz")
        require(userinfo.ageGateUncertain, "redirect userinfo rejected")
    }
}

private extension Result where Success == SiteRouteStore, Failure == SiteRoutePolicy.Rejection {
    var value: SiteRouteStore {
        if case .success(let store) = self { return store }
        fputs("unexpected rejection\n", stderr)
        exit(1)
    }
    var failureReason: String? {
        if case .failure(let error) = self { return error.reason }
        return nil
    }
}
