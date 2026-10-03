# 1.10.6 (38) sticky-list fix

## Evidence (2026-10-03)
Browser read-only DOM after age entry, forumdisplay mobile=2 fid=95 (综合讨论区): one `div.n5_zdtys` under `div.bg`, ten `ul > li` rows, each with `i` date and thread anchor. Subjects match reported permanent access, acceleration, recruitment, invitations, tutorials and service/rules notices. fid=103 uses the same container (six notices). These rows have no stickthread/displayorder/pin marker. No cookie, user screenshot or authenticated HTML is stored in this repository. SEHUATANG shell reads still returned the age gate; browser cookie import did not establish a verifiable logged-in state. Evidence is live public DOM, not a verified authenticated capture or on-device app acceptance.

## Root cause and scope
The previous parser added every bare dated li before mobile/PC cards. Global excluded IDs covered only stickthread containers, so n5_zdtys notices became anonymous entries with blank statistics. Row extraction also loses parent displayorder metadata. A duplicate dated li could precede an icon-marked sticky card and win dedup.

Forum list parsing now precomputes excluded IDs from full balanced n5_zdtys/stickthread/positive-displayorder containers AND marked li/mobile/PC rows before any branch. All three branches consult that set, preventing re-addition. Only this dedicated n5 top-notice area is hidden; portal n5_ggmk notices, normal dated li, ordinary announcements, title words, category typeid, anonymous authors and zero replies are not blanket filters. Pagination continues to read the original complete HTML, including empty filtered pages.

## Regression
Production Swift PARSER_REGRESSION_TESTS adds the live-observed container shape with sanitized invented IDs/text, duplicate mobile and PC representations, parent metadata outside card, dated fallback before icon-marked card, normal dated announcement and ordinary zero-reply/title-keyword card. Runs across fid 95/103/97; empty notices-only page retains unknown total and next-page continuation. Existing sticky, pagination, detail/image and all 115 fixtures remain enabled in CI. This fixture is reconstructed from observed DOM, not raw authenticated HTML.

No toolbar sheet, player, 115, body rendering, purchasing or favorites implementation changes. No purchase/sign-in/delete actions performed.
