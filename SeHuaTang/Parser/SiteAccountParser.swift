import Foundation

struct AccountRow: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

enum SiteAccountParser {
    static func parse(_ html: String, signing: Bool) -> (rows: [AccountRow], status: String) {
        if signing {
            let text = HTML.stripTags(html)
            let button = HTML.elements(in: html, tag: "a").first { HTML.attribute("id", in: $0) == "signin-btn" }
            let label = button.map(HTML.stripTags) ?? ""
            let signed = label.contains("已签到") && !label.contains("未签到")
            guard signed || label.contains("未签到") else { return ([], "未知签到状态") }
            var rows = [AccountRow(title: "今日签到", value: signed ? "今日已签到" : "今日未签到 · 需手动验证码")]
            if let days = HTML.firstMatch(#"累计签到\s*(\d+)\s*天"#, in: text) {
                rows.append(AccountRow(title: "累计签到", value: days + " 天"))
            }
            if let reward = HTML.firstMatch(#"累计获得\s*(\d+)\s*金钱"#, in: text) {
                rows.append(AccountRow(title: "累计奖励", value: reward + " 金钱"))
            }
            return (rows, signed ? "站点确认今日已签到；不会重复请求。" : "真实今日状态：未签到。验证码需在必要验证页手动完成。")
        }
        var rows: [AccountRow] = []
        for li in HTML.elements(in: html, tag: "li") {
            if let name = HTML.elements(in: li, tag: "em").first,
               let amount = HTML.elements(in: li, tag: "p").first,
               ["积分", "金钱", "色币", "评分"].contains(HTML.stripTags(name)) {
                rows.append(AccountRow(title: HTML.stripTags(name), value: HTML.stripTags(amount)))
            } else if let change = HTML.elements(in: li, tag: "i").first,
                      let detail = HTML.elements(in: li, tag: "a").first,
                      HTML.attribute("href", in: detail)?.contains("mod=viewthread") == true {
                rows.append(AccountRow(title: HTML.stripTags(change), value: HTML.stripTags(detail)))
            }
        }
        return (rows, "来自已登录站点实时余额 / 积分变更记录（只读）。")
    }
}
