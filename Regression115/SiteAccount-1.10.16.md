# 1.10.16 (48): live account endpoints

Read-only live checks reused the existing authenticated browser cookie store; no credentials were extracted. No authenticated HTML, cookie, screenshot, real balance, token or account identity is included.

- `plugin.php?id=dd_sign&mobile=2`: live DOM `a#signin-btn.ddpc_sign_btn_red` says 今日未签到，点击签到; cumulative days/reward present. No form. Site loads `source/plugin/dd_sign/static/js/captcha.js`.
- Live JS requires `GET misc.php?mod=captcha`, interactive click/slide/drag/rotate challenge, `POST misc.php?mod=captcha&action=check` with text/plain answer; only ret.data == ok then `GET plugin.php?id=dd_sign&ac=sign_v2`. Captcha encountered: stopped, neither captcha verification POST nor sign write GET sent. Sign writes=0, all mutation POSTs=0. No bypass or speculative sign request. Because no write dispatch exists in native code, no ambiguous retry exists.
- `home.php?mod=spacecp&ac=credit&showcredit=1&mobile=2`: real four balances: 积分/金钱/色币/评分. Live li/em/p balances and li/i/span plus thread anchor ledger parsed natively. Values/title/tid replaced in live-derived fixtures. `op=log` read-only variant also checked; mobile template supplies same balance/record structure, with no confirmed ledger pager in sampled response. Native pager only accepts same-host credit next links.
- `home.php?mod=space&do=favorite&type=thread&mobile=2`: live li.item with squareProgressBox thread anchors, delete control separate; native parser reads same-host thread rows only and never invokes delete. Existing pagination retained.
- `home.php?mod=space&do=follow&view=following&mobile=2`: site explicitly says 抱歉，广播功能尚未开启. Native UI now displays unavailable rather than implying empty/parser failure.
- Favorite confirmation GET: form action `home.php?mod=spacecp&ac=favorite&type=thread&id=<tid>&spaceuid=0&mobile=2`; hidden favoritesubmit/referer/formhash, textarea description, submit favoritesubmit_btn. No favorite/attention write performed.

Native: Mine credit balance/ledger and daily sign state/cumulative rewards. Verification-only web fallback for real captcha signing; login/Cloudflare, purchase confirmation, favorite mutation and original-page content fallback stay explicit. No automatic purchase/reply/delete or follow operations. Existing native reply safe form protocol retained; no further reply sent. No claim of successful live sign or real-device app verification. Player/115/media/copy/sticky/fid97 purchase guards untouched.

CI adds production account parser fixtures alongside all prior regression suites and iphoneos unsigned build.
