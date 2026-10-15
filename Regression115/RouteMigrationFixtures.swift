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
        manualRouteLifecycle()
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
            "https://localhost",
            "https://forum.local",
            "https://host.internal",
            "https://[::1]",
            "https://2130706433",
            "https://127.1",
            "https://foo.com?",
            "https://foo.com#",
            "https://foo.com/?query=1",
            "https://foo.com/#fragment",
            "https://foo_bar.com",
            "https://-foo.com",
            "www.sehuatang.org/forum.php",
            "https://www.sehuatang.org/path",
            "ftp://www.sehuatang.org",
            "https://foo.invalid",
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
        var store = SiteRouteStore.fresh().adding("https://forum.swift.org").value
        store = store.settingEnabled("98tang.com", false)
        store = store.removing("www.sehuatang.org")
        require(store.routes.contains { $0.host == "www.sehuatang.org" && $0.builtin }, "builtin cannot be deleted")
        let removed = store.removing("forum.swift.org")
        require(!removed.routes.contains { $0.host == "forum.swift.org" }, "manual route removed")
        let json = String(data: store.persistedJSON(), encoding: .utf8) ?? ""
        require(!json.contains("secret"), "route config has no secret")
        require(!json.contains("cookie"), "route config has no cookie")
        require(!json.contains("password"), "route config has no password")
        let loaded = SiteRouteStore.load(data: store.persistedJSON(), legacyHost: "http://evil.example")
        require(loaded.routes.map(\.host).starts(with: SiteRoutePolicy.builtinHosts), "builtins restored")
        require(loaded.routes.first { $0.host == "98tang.com" }?.enabled == false, "disabled flag persists")
    }

    static func manualRouteLifecycle() {
        var store = SiteRouteStore.fresh().adding(" HTTPS://FORUM.SWIFT.ORG:443/ ").value
        store = store.adding("forum.swift.org").value
        require(store.routes.filter { $0.host == "forum.swift.org" }.count == 1, "normalized duplicate deduplicated")
        require(store.routes.first { $0.host == "forum.swift.org" }?.builtin == false, "custom route deletable")
        store.selectedHost = "forum.swift.org"
        store = store.removing("forum.swift.org")
        require(store.selectedHost == SiteConfig.defaultHost, "selected deletion falls back to default")
        for host in store.enabledHosts { store = store.settingEnabled(host, false) }
        require(!store.enabledHosts.isEmpty, "last disabled route restores usable default")
        require(store.selectedHost == SiteConfig.defaultHost && store.enabledHosts.contains(store.selectedHost), "fallback is enabled")
        var stale = store
        stale.selectedHost = "deleted.swift.org"
        require(stale.normalized().selectedHost == SiteConfig.defaultHost, "dangling selection repaired")
        store = store.adding("forum.swift.org").value
        store.selectedHost = "forum.swift.org"
        store = store.settingEnabled("forum.swift.org", false)
        require(store.selectedHost == SiteConfig.defaultHost, "active disable falls back")
    }

    static func directOrgMigration() {
        require(SiteRoutePolicy.sameSiteDirect("www.sehuatang.org", "sehuatang.org"), "org pair")
        require(!SiteRoutePolicy.requiresReadOnlyVerification("sehuatang.org", "www.sehuatang.org"), "direct pair skips probe")
        let decision = RouteMigration.decision(
            source: "www.sehuatang.org", target: "sehuatang.org", hasCookies: true, probe: nil)
        require(decision == .direct, "org migrates without probe")
        let ledger = RouteCookieLedger(scopes: [
            "www.sehuatang.org": [ScopedCookie(name: "auth", value: "token", path: "/", secure: true, expires: nil)]
        ])
        require(ledger.migrating(from: "www.sehuatang.org", to: "sehuatang.org") == nil,
                "host-only credentials are never widened even within org")
        // Domain cookies are left in native WK storage, not adapted by a ledger.
    }

    static func verifiedFamilyMigration() {
        let ledger = RouteCookieLedger(scopes: [
            "www.sehuatang.org": [ScopedCookie(name: "auth", value: "token", path: "/", secure: true, expires: nil)]
        ])
        for target in ["www.sehuatang.net", "98tang.com", "forum.swift.org", "www.sehuatang.org.evil.com"] {
            let forged = RouteMigration.Probe(finalHost: target, challenged: false,
                ageGateUncertain: false, siteMarker: true, redirects: 0)
            if case .rejected = RouteMigration.decision(source: "www.sehuatang.org", target: target, hasCookies: true, probe: forged) {} else {
                require(false, "forged forum markers never authorize migration")
            }
            require(ledger.migrating(from: "www.sehuatang.org", to: target) == nil, "cross-domain cookie copy forbidden")
            require(!SiteRoutePolicy.permitsNavigation(URL(string: "https://\(target)/")!, selectedHost: "www.sehuatang.org"), "redirect cannot visit other host with its cookies")
        }
    }

    static func rejectCrossSiteAndChallenge() {
        for final in ["www.sehuatang.net", "98tang.com", "forum.swift.org"] {
            for challenged in [true, false] {
                let probe = RouteMigration.Probe(finalHost: final, challenged: challenged,
                    ageGateUncertain: challenged, siteMarker: !challenged, redirects: 1)
                if case .rejected = RouteMigration.decision(source: "www.sehuatang.org", target: final, hasCookies: true, probe: probe) {} else {
                    require(false, "no challenge or HTML outcome can transfer login")
                }
            }
        }
        for bad in ["http://www.sehuatang.org/", "https://user:pass@www.sehuatang.org/", "https://www.sehuatang.org:8443/", "https://127.0.0.1/"] {
            require(!SiteRoutePolicy.permitsNavigation(URL(string: bad)!, selectedHost: "www.sehuatang.org"), "unsafe authenticated redirect refused")
        }
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
