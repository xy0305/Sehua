# Search pagination live evidence — 2026-10-08

Baseline origin/main: 88455f913f9cdc0653709e805d3f79ce38888c7f. Local 6a877c4 had the same tree; changes are on a separate branch, not a forced main update.

## Actual site test
Browser used the existing website cookie store; an age-confirmation page appeared and was accepted. The resulting site has a login link, no logout link: this is a real anonymous browsing session, NOT a verified logged-in account. No password was entered. Search GETs and following result pagination only; no purchase, favorite, forum POST or 115 writes.

Query: 巨乳. Mobile search returned 30 distinct tids on page 1. Following the site's next-page anchor produced page 2: 30 tids, 30 newly distinct, cumulative 60. Following its next-page anchor produced page 3: 30 tids, 30 newly distinct, cumulative 90; next page 4 exists. No thread titles, body, cookies, formhash or signature values recorded here.

Actual redacted next-link structure:
search.php?mod=forum&searchid=REDACTED&searchmd5=REDACTED&orderby=lastpost&ascdesc=desc&searchsubmit=yes&kw=REDACTED&page=2&mobile=2
Page 2 and 3 use the same structure with page=3 / page=4. DOM anchor was double-quoted. searchid was present (actual numeric value 0); presence rather than positivity is required. The signature must be retained privately when navigating, not replaced or re-created.

Control: requesting old implementation's searchsubmit=yes&srchtxt=...&page=2 redirected to a search URL WITHOUT page. Returned 30 tids matched original page 1 (30/30), matched page 3 (0/30). Thus the site discards page on repeated initial submission; dedupe leaves the app at 30. This is directly observed, not a conjecture about regex quotes.

## Change scope
AppStore keeps the exact validated server cursor and retries that address. Only the initial request submits srchtxt. Cursor validation: HTTPS, same host/port, no credentials or fragment, /search.php, unique mod=forum, unique strictly increasing canonical integer page, unique searchid. Previously visited targets and decreasing pages are rejected. No result-count guessing; overlapping or zero newly unique IDs do not end pagination if a cursor exists.
Clear resets searchQuery/cursor/visited/generation. Automatic append is idle-only (failed append requires explicit retry). Existing loaded hits remain during failed replacement/append. View allows new search cancellation while loading and uses a page-keyed sentinel. Generation and WebSession task cancellation already isolate stale requests. WebSession accepts absolute URLs and cancels active/queued requests; fetchHTML returns HTML only, not final URL. Relative next anchors resolve safely against the requested same-site /search.php URL; no signature is reconstructed.

Fixtures exercise production DiscuzParser, actual redacted query shape, reordered/single-quoted href, amp entities, cross-site/insecure/thread-page/duplicate/invalid page rejection, 90 synthetic IDs and overlap/end behavior. Fixture IDs are synthetic, not live counts. No logged-in iPhone acceptance claimed. CI compilation and full iphoneos build are required before release; no version bump/release until verified.
