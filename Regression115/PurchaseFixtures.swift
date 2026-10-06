import Foundation
@main struct PurchaseFixtures {
    static func main() throws {
        let base = URL(string: "https://www.sehuatang.org/forum.php?mod=viewthread&tid=3743663&mobile=2")!
        let html = #"<form method="post" action="forum.php?mod=misc&action=pay&paysubmit=yes&infloat=yes"><input type="hidden" name="formhash" value="dynamic"><input type="hidden" name="referer" value=""><input type="hidden" name="tid" value="3743663"><input type="submit" name="paysubmit" value="true"></form>"#
        let form = try NativePurchaseProtocol.form(html, base: base, tid: 3743663)
        precondition(form.action.absoluteString == "https://www.sehuatang.org/forum.php?mod=misc&action=pay&paysubmit=yes&infloat=yes")
        precondition(form.fields["formhash"] == "dynamic" && form.fields["tid"] == "3743663" && form.fields["paysubmit"] == "true")
        let duplicate = NativePurchaseProtocol.outcome("<div>抱歉，您已购买过此主题，请勿重复付费</div>")
        guard case .failure(.alreadyPurchased) = duplicate else { preconditionFailure("duplicate purchase not recognised") }
        let rejected = NativePurchaseProtocol.outcome("<div>抱歉，您的金钱不足</div>")
        guard case .failure(.rejected(let message)) = rejected, message.contains("金钱不足") else { preconditionFailure("explicit rejection lost") }
        precondition((try? NativePurchaseProtocol.form(html.replacingOccurrences(of: "3743663", with: "1"), base: base, tid: 3743663)) == nil)
        let encoded = String(data: NativePurchaseProtocol.encode(["paysubmit": "true", "tid": "3743663"]), encoding: .utf8)
        precondition(encoded == "paysubmit=true&tid=3743663")
        print("PASS native purchase protocol")
    }
}
