import Foundation
@main struct SiteAccountFixtures {
    static func main() {
        // Captured authenticated live DOM, reduced to relevant nodes; values and titles replaced.
        let credit = """
        <li><em>积分</em><p>123</p></li>
        <li><em>金钱</em><p>123</p></li>
        <li><em>色币</em><p>123</p></li>
        <li><em>评分</em><p>123</p></li>
        <li><i>金钱 <span class="xg1">-10</span></i><a href="forum.php?mod=viewthread&amp;tid=42&amp;mobile=2" target="_blank">购买 已脱敏主题 的主题支出积分</a></li>
        """
        let parsed = SiteAccountParser.parse(credit, signing: false)
        precondition(parsed.rows.count == 5)
        precondition(parsed.rows[1].title == "金钱" && parsed.rows[1].value == "123")
        precondition(parsed.rows[4].title == "金钱 -10")
        let sign = "<a id=\"signin-btn\" class=\"ddpc_sign_btn_red\">今日未签到，点击签到</a><div>累计签到 12天累计获得 24金钱</div>"
        let unsigned = SiteAccountParser.parse(sign, signing: true)
        precondition(unsigned.rows.count == 3 && unsigned.status.contains("未签到"))
        // State variants are synthetic; no successful write was performed (captcha required).
        let signed = SiteAccountParser.parse(sign.replacingOccurrences(of: "今日未签到，点击签到", with: "今日已签到"), signing: true)
        precondition(signed.status.contains("不会重复"))
        precondition(SiteAccountParser.parse("<div>请登录</div>", signing: true).rows.isEmpty)
        precondition(SiteAccountParser.parse("<div>验证码</div>", signing: false).rows.isEmpty)
        print("Live-derived account fixtures passed")
    }
}
