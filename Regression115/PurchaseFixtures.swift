import Foundation

@main
struct PurchaseFixtures {
    static func main() {
        let base = URL(string: "https://example.test/forum.php?mod=viewthread&tid=42&mobile=2")!
        func page(_ body: String, fid: Int = 103, control: String = "", reply: String = "") -> String {
            "<div id='pt'><a href='forum.php?mod=forumdisplay&fid=\(fid)'>区</a></div><div id='post_10'>\(control)<div id='postmessage_10' class='t_f'>\(body)</div></div>\(reply)"
        }
        func parse(_ s: String) -> ThreadDetail { DiscuzParser.parseThreadDetail(s, tid: 42, base: base) }
        let pay = "<div class='locked'>购买本主题需支付 12 金币 <a href='forum.php?mod=misc&amp;action=pay&amp;tid=42'>购买</a></div>"
        precondition(parse(page("可见免费正文")).purchaseState == .free)
        let paid = parse(page(pay))
        guard case .required(let price, let entry) = paid.purchaseState else { fatalError("AI paid") }
        precondition(price == "12 金币" && entry?.host == base.host)
        guard case .required = parse(page(pay, fid: 95)).purchaseState else { fatalError("other board") }
        precondition(parse(page("免费正文", fid: 97)).purchaseState == .free)
        let bought = page("已解锁资源 https://example.test/file", control: "<div>您已经购买过此主题</div>")
        precondition(parse(bought).purchaseState == .purchased && parse(bought).posts[0].plainText.contains("已解锁资源"))
        precondition(parse(page("我已经购买，付费很好", reply: "<div id='post_11'><div class='message'>您已经购买过此主题\(pay)</div></div>")).purchaseState == .free)
        precondition(parse(page("正文", control: "<aside><a href='forum.php?mod=misc&action=pay&tid=42'>广告支付</a></aside>")).purchaseState == .free)
        for forged in [pay.replacingOccurrences(of: "tid=42", with: "tid=43"), pay.replacingOccurrences(of: "forum.php?", with: "https://evil.test/forum.php?")] {
            guard case .required(_, let url) = parse(page(forged)).purchaseState else { fatalError("real gate still required") }
            precondition(url == nil)
        }
        precondition(parse("<div>导航</div>").purchaseState == .unknown)
        precondition(parse(page("正文") + "<div>cf-chl-platform</div>").purchaseState == .unknown)
        precondition(parse("<form><input name='password'></form>").purchaseState == .unknown)
        precondition(parse(page("<div class='locked'>回复后可见</div>")).purchaseState == .unknown)
        precondition(parse(page("<div class='locked'>阅读权限 100</div>")).purchaseState == .unknown)
        var current = paid
        current = parse(bought)
        precondition(current.purchaseState == .purchased)
        current = parse(page("免费正文"))
        precondition(current.purchaseState == .free)
        current = parse("请先登录")
        precondition(current.purchaseState == .unknown)
        let noPrice = parse(page(pay.replacingOccurrences(of: "12 金币", with: "***")))
        guard case .required(let missing, _) = noPrice.purchaseState else { fatalError("missing price") }
        precondition(missing == nil)
        print("PASS purchase: AI free/required/purchased, any fid, replies/ads, cross tid/host, login/CF, permission/reply gates, refresh, no invented price")
    }
}
