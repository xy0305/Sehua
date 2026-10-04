import Foundation

@main struct NativeReplyFixtures {
    static func main() throws {
        let base = URL(string: "https://sehuatang.org/forum.php")!
        let tid = 3807868, fid = 141
        let action = "forum.php?mod=post&infloat=yes&action=reply&fid=141&extra=&tid=3807868&replysubmit=yes&inajax=1"
        // Synthetic credential only; no authenticated page or real token stored.
        let form = """
        <div id="floatlayout_reply"><form method="post" id="postform" action="\(action.replacingOccurrences(of: "&", with: "&amp;"))">
        <input type="hidden" name="formhash" value="SYNTHETIC_ONLY">
        <input type="hidden" name="handlekey" value="reply">
        <input type="hidden" name="noticeauthor" value=""><input type="hidden" name="noticetrimstr" value=""><input type="hidden" name="noticeauthormsg" value="">
        <input type="checkbox" name="usesig" value="1" checked><input type="hidden" name="subject" value="">
        <textarea name="message" id="postmessage"></textarea><button type="submit">参与/回复主题</button></form></div>
        """
        let parsed = try NativeReplyProtocol.form(form, base: base, tid: tid, fid: fid)
        precondition(parsed.fields["formhash"] == "SYNTHETIC_ONLY" && parsed.fields["usesig"] == "1")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script type="text/javascript" reload="1">succeedhandle_reply('forum.php?mod=viewthread&tid=3807868&pid=71235431&page=5&extra=#pid71235431','非常感谢，回复发布成功，现在将转入主题页',{'fid':'141','tid':'3807868','pid':'71235431','from':'','sechash':''});</script>]]></root>
        """
        let result = try NativeReplyProtocol.success(xml, base: base, tid: tid)
        precondition(result.page == 5 && result.pid == 71235431)
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Unsafe fixture accepted") } catch {}
        }
        for bad in [form.replacingOccurrences(of: "forum.php?", with: "https://evil.invalid/forum.php?"), form.replacingOccurrences(of: "tid=3807868", with: "tid=2"), form.replacingOccurrences(of: "fid=141", with: "fid=97"), form.replacingOccurrences(of: "</form>", with: "<input name='seccodeverify'></form>"), form.replacingOccurrences(of: "name=\"noticeauthor\" value=\"\"", with: "name=\"noticeauthor\" value=\"123\""), form.replacingOccurrences(of: "</form>", with: "<input type='hidden' name='unsupported' value='1'></form>")] {
            rejects { _ = try NativeReplyProtocol.form(bad, base: base, tid: tid, fid: fid) }
        }
        for bad in ["<html>HTTP200</html>", "<root>bad</root>", xml.replacingOccurrences(of: "forum.php?mod=viewthread", with: "https://evil.invalid/forum.php?mod=viewthread"), xml.replacingOccurrences(of: "'tid':'3807868'", with: "'tid':'2'"), xml.replacingOccurrences(of: "'pid':'71235431'", with: "'pid':'1'")] {
            rejects { _ = try NativeReplyProtocol.success(bad, base: base, tid: tid) }
        }
        let failed = "<root><![CDATA[<script>errorhandle_reply('回复时间间隔限制',{});</script>]]></root>"
        do { _ = try NativeReplyProtocol.success(failed, base: base, tid: tid); fatalError() }
        catch NativeReplyProtocol.ReplyError.rejected {} 
        let encoded = String(data: NativeReplyProtocol.encode(["message": "中文 +&=\n🙂"]), encoding: .utf8)!
        precondition(encoded == "message=%E4%B8%AD%E6%96%87%20%2B%26%3D%0A%F0%9F%99%82")
        let suite = "ReplyFixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = NativeReplyProtocol.DispatchGate(defaults: defaults)
        try gate.begin("thread")
        precondition(NativeReplyProtocol.DispatchGate(defaults: UserDefaults(suiteName: suite)!).locked("thread"))
        rejects { try gate.begin("thread") } // timeout/unknown/process restart never auto-reposts
        gate.resolved("thread") // only explicit known resolution
        try gate.begin("thread")
        print("Native reply production fixtures passed: form, XML, captcha, scope, encoding, persistent unknown gate")
    }
}
