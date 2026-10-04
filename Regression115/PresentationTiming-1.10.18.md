# 1.10.18 (50): presentation timing audit

## Carousel
- Existing TabView paging, fixed 220–280pt geometry, cookie-aware images, bounded GIF decoding and full-screen zoom are retained.
- Four-second cancellable task, enabled only for multiple images, an appeared image pager intersecting the screen, active scene, no drag, no full-screen image, and Reduce Motion disabled.
- A simultaneous drag does not replace the pager gesture. Drag begin cancels the task; release or page selection starts a fresh four-second interval. Disappearance and background cancel ticks. Geometry observation changes only a Boolean, not layout or row height.
- Geometry uses the screen rectangle as a conservative viewport approximation; safe-area/overlay occlusion is not measured. No claim of physical-device gesture validation.

## Detail audit / evidence
- WebSession uses a single authenticated WKWebView with serial queue; request deadline includes queue waiting. Navigations ignore local URL cache. This is intentional: concurrent navigation would replace the active document and risk cross-request responses and cookie/challenge state.
- Before this patch didCommit starts a sampler, then didFinish unconditionally increments collectGen and starts another. A thread needs complete readiness and two equal messageBodies snapshots: .4s first sample + .7s second sample. Resource finish can discard the earlier body snapshot and impose a fresh 1.1s window; each queued request inherits predecessor overhead.
- didFinish now retains the sampler only when its generation matches this navigation's commit sampler. If absent, it still starts one. Navigation start, request completion, cancellation and timeout still invalidate generations. This removes duplicated work, not the safety interval.
- The controlled regression timeline commit=0, finish=.5 shows earliest retained acceptance=1.1 versus restarted=1.6. This is not a live latency measurement or a speed percentage.
- Thread collection still requires complete document and unchanged message bodies .7s apart, with unchanged 24-attempt bounds, challenge/age-gate handling, and permission pages. No prefix HTML/body shortcut, speculative detail fetch, parallel WebView, HTTP cookie reimplementation or sensitive HTML persistence was introduced.
- ThreadDetailView.load fetches once, checks cancellation/requestGate, rejects challenges/unreadable posts, parses full HTML then assigns detail and records reading history. It has no explicit extra timer or image-download barrier. Parsing stays on the main actor: moving UIKit-attributed-string parsing to a worker without isolation review is not safe in this patch.
- Page/resource network latency, authentication, queue occupancy, parser CPU cost and a genuinely changing body can still delay display. No timing reduction is promised for these paths.

## Validation
- Production PresentationTiming policy fixtures run on macOS CI alongside all existing parser completeness, body routing, GIF, account and 115 fixtures.
- The timing fixtures assert lifecycle gating and sampler reuse/fallback, not a real WKWebView runtime. Existing content fixtures remain the full-body regression safety net.
- Build Release unsigned iphoneos on macOS CI; local iSH has no Swift SDK. Do not describe this as real-device acceptance.
- No site reply, purchase, check-in or 115 write operation is used by this change.
