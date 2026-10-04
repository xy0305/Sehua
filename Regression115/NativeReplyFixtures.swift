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
        // PC/mobile safe optional controls: empty security hash is not a challenge.
        let optional = "<input type='hidden' name='sechash' value=''><input type='hidden' name='from' value=''><input type='hidden' name='posttime' value='123'><input type='hidden' name='wysiwyg' value='0'><input type='hidden' name='fid' value='141'><input type='hidden' name='tid' value='3807868'><input name='ignored_disabled' disabled><input type='checkbox' name='unused' value='1'>"
        let pc = form.replacingOccurrences(of: "</form>", with: optional + "<script>var template = \"<input name='seccodeverify'><div id='captcha'></div>\";</script></form>")
        let mobile = form.replacingOccurrences(of: "<input type=\"hidden\" name=\"noticeauthormsg\" value=\"\">", with: "<textarea name='noticeauthormsg'></textarea>")
        for good in [pc, mobile, "<div id='captcha_elsewhere'></div>" + form, form.replacingOccurrences(of: "</form>", with: "<!-- <input name='seccodeverify'> --><template><input name='captcha'></template></form>")] {
            let accepted = try NativeReplyProtocol.form(good, base: base, tid: tid, fid: fid)
            precondition(accepted.fields["noticeauthor"] == "" && accepted.fields["noticeauthormsg"] == "")
        }
        func diagnostic(_ markup: String, contains category: String) {
            do { _ = try NativeReplyProtocol.form(markup, base: base, tid: tid, fid: fid); fatalError("Expected diagnostic") }
            catch NativeReplyProtocol.ReplyError.diagnostic(let reason) { precondition(reason.contains(category) && !reason.contains("SECRET_VALUE")) }
            catch { fatalError("Wrong diagnostic: \(error)") }
        }
        diagnostic(form.replacingOccurrences(of: "SYNTHETIC_ONLY", with: ""), contains: "formhash")
        diagnostic(form.replacingOccurrences(of: "</form>", with: "<input name='from' value='SECRET_VALUE'></form>"), contains: "来源语义")
        diagnostic(form.replacingOccurrences(of: "</form>", with: "<input name='seccodeverify'></form>"), contains: "验证码")
        diagnostic(form.replacingOccurrences(of: "</form>", with: "<input name='sechash' value='SECRET_VALUE'></form>"), contains: "安全验证")
        diagnostic(form.replacingOccurrences(of: "</form>", with: "<input name='required_custom' required value='SECRET_VALUE'></form>"), contains: "required_custom")
        diagnostic(form.replacingOccurrences(of: "name=\"noticeauthor\" value=\"\"", with: "name=\"noticeauthor\" value=\"SECRET_VALUE\""), contains: "引用回复")
        diagnostic(form.replacingOccurrences(of: "</form>", with: "<textarea name='noticeauthormsg'>SECRET_VALUE</textarea></form>"), contains: "重复字段")
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
        // Read-only live mobile postform sampled 2026-10-04, tid=3804384/fid=141.
        // Public title normalized; credential and clock replaced. No authenticated page stored.
        let live = """
        <form method="post" id="postform" enctype="multipart/form-data" action="forum.php?mod=post&amp;action=reply&amp;fid=141&amp;tid=3804384&amp;extra=&amp;replysubmit=yes&amp;mobile=2">
        <input type="hidden" name="formhash" id="formhash" value="SYNTHETIC_ONLY">
        <input type="hidden" name="posttime" id="posttime" value="1234567890">
        <input type="hidden" name="wysiwyg" id="e_mode" value="1">
        <input type="hidden" name="noticeauthor" value=""><input type="hidden" name="noticetrimstr" value=""><input type="hidden" name="noticeauthormsg" value="">
        <div class="n5_fbztnr cl"><ul class="cl"><li><div class="cl"><div class="n5_fbztbt inbox"><div>RE: PUBLIC_TITLE</div></div></div></li>
        <div id="container" class="n5_fbbqqj cl"><div class="n5_nrbjcr cl"><li><a href="JavaScript:void(0)" id="message_face" class="n5_bqanys"></a></li>
        <li><a href="javascript:;" id="addimg" class="n5_bqantp"><input type="file" name="Filedata" id="filedata" style="width: 25px;opacity:0;"></a></li></div>
        <li class="n5_fbztxx area cl"><textarea class="pt mtm nrk" id="needmessage" tabindex="3" autocomplete="off" name="message" cols="80" rows="2" placeholder="内容" fwin="reply"></textarea></li></div></ul>
        <ul id="imglist" class="post_imglist cl"></ul><span class="n5_fbztdtb"><button id="postsubmit" class="btn_pn btn_pn_grey" disable="true"><span>回复</span></button></span></div></form>
        """
        // Live DOM files.length == 0 and required == false, not inferred from HTML value.
        for sample in [live, "<?xml version='1.0'?><root><![CDATA[" + live + "]]></root>"] {
            let actual = try NativeReplyProtocol.form(sample, base: base, tid: 3804384, fid: 141, emptyFileInputs: ["Filedata"])
            precondition(actual.fields["Filedata"] == nil && actual.fields["wysiwyg"] == "1" && actual.fields["posttime"] == "1234567890")
            precondition(actual.fields["formhash"] == "SYNTHETIC_ONLY" && HTML.queryInt("tid", in: actual.action.absoluteString) == 3804384)
        }
        rejects { _ = try NativeReplyProtocol.form(live, base: base, tid: 3804384, fid: 141) }
        for bad in [live.replacingOccurrences(of: "type=\"file\"", with: "type=\"file\" required"), live.replacingOccurrences(of: "type=\"file\"", with: "type=\"file\" value=\"selected.jpg\""), live.replacingOccurrences(of: "name=\"Filedata\"", with: "name=\"OtherUpload\""), live.replacingOccurrences(of: "</form>", with: "<input type='hidden' name='attachment' value='1'></form>"), live.replacingOccurrences(of: "</form>", with: "<input name='seccodeverify'></form>"), live.replacingOccurrences(of: "name=\"noticeauthor\" value=\"\"", with: "name=\"noticeauthor\" value=\"123\"")] {
            rejects { _ = try NativeReplyProtocol.form(bad, base: base, tid: 3804384, fid: 141, emptyFileInputs: ["Filedata"]) }
        }
        rejects { _ = try NativeReplyProtocol.form("<!DOCTYPE root>" + live, base: base, tid: 3804384, fid: 141) }
        // page belongs to URL, not callback object; omitting object.page is valid.
        let page45 = xml.replacingOccurrences(of: "page=5", with: "page=45")
        let page45Result = try NativeReplyProtocol.success(page45, base: base, tid: tid)
        precondition(page45Result.page == 45)
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
