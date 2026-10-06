import Foundation

@main struct NativeActionFixtures {
    static func main() throws {
        precondition(NativeSignProtocol.ready(#"{"code":200,"data":"ok"}"#))
        precondition(!NativeSignProtocol.ready(#"{"code":200,"data":"failure"}"#))
        guard case .success = NativeSignProtocol.outcome(#"{"code":200,"message":"签到成功"}"#) else { preconditionFailure("sign success") }
        guard case .failure(.rejected) = NativeSignProtocol.outcome(#"{"code":1,"message":"验证超时，请重新验证"}"#) else { preconditionFailure("sign rejection") }
        let base = URL(string: "https://www.sehuatang.org/home.php?mod=spacecp&ac=favorite&type=thread&id=42&mobile=2")!
        let html = #"<form method="post" action="home.php?mod=spacecp&ac=favorite&type=thread&id=42"><input name="formhash" value="dynamic"><input name="referer" value=""><input name="favoritesubmit" value="true"><textarea name="description"></textarea></form>"#
        let form = try NativeFavoriteProtocol.form(html, base: base, tid: 42)
        precondition(form.action.host == base.host && form.fields["formhash"] == "dynamic" && form.fields["favoritesubmit"] == "true")
        guard case .failure(.already) = NativeFavoriteProtocol.outcome("<div>抱歉，您已收藏，请勿重复收藏</div>") else { preconditionFailure("duplicate favorite") }
        precondition((try? NativeFavoriteProtocol.form(html, base: base, tid: 43)) == nil)
        print("PASS native sign and favorite protocols")
    }
}
