# 1.10.15 (47) — native reply false-positive diagnostics

## Changes
- Restrict challenge detection to the selected same-host HTTPS/same tid/fid reply form; remove script/comment/template markup before parsing.
- Accept empty `sechash`/`from` and empty notice textareas; retain rejection of nonempty security/quote/source semantics, unknown/duplicate fields, invalid formhash and scope mismatch.
- Skip disabled and unchecked controls; default missing signature checkbox to 0.
- Categorized diagnostics expose only bounded safe field names, never values.
- Existing XML success checks and persistent unknown-result dispatch gate unchanged. No business UI or 115 integration changes.

## Authorized live investigation (2026-10-04)
Target tid 3804384, observed fid 141. Cookie imported via subprocess with values suppressed. Normal age-confirmation entrance opened the requested thread. Ordinary reply GET (`forum.php?mod=post&action=reply&fid=141&tid=3804384&mobile=2`) redirected to `member.php?mod=logging&action=login&mobile=2`, with password control present. Thus the supplied Cookie did not provide an authenticated reply form in this browser. No POST, no requested message sent, no successful pid/page, no bypass attempted. Public thread formhash is not treated as an authenticated reply credential. No real Cookie/formhash persisted in source or report.

## Verification
Regression fixtures cover safe optional fields, empty notice textarea, script/comment/template exclusions, unrelated external captcha, genuine challenge, nonempty security hash, quote/source semantics, unknown and duplicate controls, missing hash, same-host scope, XML pid/tid, HTTP200-not-success, encoding and persistent anti-duplicate gate. CI also retains the complete parser/resource/content/routing/animation/115 fixture suite and unsigned iPhoneOS Release build. Physical-device installation and real authenticated posting remain unverified.
