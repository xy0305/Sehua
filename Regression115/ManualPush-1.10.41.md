# Native manual push — 1.10.41 (73)

## Reference actually inspected (never executed)

Uploaded `/var/minis/attachments/uploads/4DB4D2882308CE901DED63801CDAAC87_1.js` (207676 bytes):

- lines 50–94: `uniqueArray`, `matchLinksFast`, `normalizeDownloadLink`, `isValidDownloadLink`.
- lines 1934–2071: `addWebTorrents` account binding, target override / folder selection, queue handoff and archive monitoring.
- lines 3837–3906: `handleLinks`, `showManualInputDialog`, multiline parsing, custom folder preview and explicit confirmation.
- line 4058: discoverable manual-input entry.

Adopted: a separate input surface, multiline extraction, deduplication, link preview, account/target review and explicit submit confirmation. Reused the native `ResourceLinkExtractor.links(in:)` rather than running or embedding the uploaded JS; native magnet hash validation is intentionally stricter than the JS's `xt=` presence check. Did not adopt console URL/error logging, automatic title folder creation for manual submissions, queue clearing, broad junk cleanup or password guessing.

## Entry and semantics

`我的 → 115资源任务 → 手动推送 ed2k / 磁力`; post resource page also links to `独立手动推送 ed2k / 磁力（不关联此帖）`.

The native page uses `TextEditor` plus the system `PasteButton`. Clipboard data is not read on opening, task startup or background execution. Input is in ephemeral view state until explicit confirmation; no new logging or diagnostic export contains the input or credentials. The established private task journal necessarily retains submitted URLs for exact replay prevention and progress attribution, with mode 0600 and atomic writes.

Supported: valid ed2k file links (positive file size, 32-digit hash, optional h= hash), magnet btih hexadecimal/base32 and btmh SHA256. Mixed text is extracted without selecting only archives; unsupported HTTP/share/password links are not submitted or dereferenced. Exact duplicates and same-resource hash variants collapse in preview and submission. ed2k identity is its 32-digit content hash (not filename/declared size); magnet identity covers every valid btih/btmh xt, normalizes base32 btih to hexadecimal and ignores trackers/display names. Hybrid magnets retain all aliases when collapsed. Different hashes of equally named/sized files remain distinct. Up to 50 unique valid resources per confirmation; preview displays total and type counts.

Target: the current selected parent CID **itself**, not a new fictional post directory. The page and confirmation show UID and CID. To select another archive directory, use the existing 115 settings browser/validation first. Immediately before submission the current settings snapshot and real target path are checked. The confirmation freezes links and settings; cancel discards only the authorization, and the busy gate is set synchronously before starting the submit task. CID stays a decimal string (including 19 digits). This scope deliberately adds no optional folder-creation flow.

A stable `manual-<account+parent digest>` record has `manualInput=true`, `tid=""` and `directoryCID=parentCID`. It is independent of every post and never fabricates a numeric tid. Old records decode unchanged through optional metadata. Detail/list labels explicitly identify manual provenance.

## Safety and provenance

Preparation is network-read-only and creates no cloud folder. Existing `SHT115Service.submit` handles final path verification, signature, one-link/batch request fields, durable pre-write task journal, 1.1-second request pacing and exact per-item returned URL identity checks. No request falls back to an insecure TLS mode.

Accepted or unknown/submitting URLs cannot be replayed through the manual record; manual submissions also check the same account's other records, including original post unknown records. Post submissions likewise cannot bypass a manual accepted/unknown lock. Clearly rejected submissions remain eligible for an explicit new attempt. Partially accepted or mismatched batch responses lock the entire attempted batch as unknown. Restart and read-only directory/task inspection preserve unknown locks; absence is not authorization to resend.

Automatic extraction follows the existing global switch. Enrollment still requires a complete unique pre-submit directory snapshot and full batch acceptance. Existing queue checks retain hash+CID task completion, unique new source file, exact name/size/SHA1/pick-code, bounded attempts, archive source journal, password/multipart retention and output verification before recycling only the proven original archive. Same-target competing link name/size detection covers all this account's local records, not just the manual record. Unknown, historical or unproven files do not become authorized by this entry point. Direct-parent path checks validate the entire ancestry without incorrectly requiring the selected directory to be its own child; recursive child paths retain direct-parent checks.

## Regression coverage and acceptance limits

`Regression115/ManualPushFixtures.swift` compiles with production service, extractor and models and intercepts all transport using URLProtocol; it never uses a real Cookie or a real cloud write. Covers empty/unsupported input, mixed text, exact duplicates, base32, percent-escaped magnet data, invalid submission input, 19-digit target, read-only preparation/stable manual ID, no folder writes, wrong-current-parent rejection, durable journal before POST, accepted batch, partial/mismatched batch, transport uncertainty, rejection, restart/repeated-send prevention, read-only reconciliation lock preservation and both directions of manual/post replay prevention. Additional fixtures cover renamed/changed-size ed2k, tracker variants, hybrid magnet aliases, base32/hex identity, different-hash and different-account isolation, draft clearing and cancelled tasks with zero writes. `ManualPushUIGuards.py` checks explicit system paste, no automatic clipboard read, frozen confirmation, cancel/clear controls, keyboard action and discoverability at source level; these are not device UI interaction tests. Full existing CI remains enabled, including image readiness (72), search (69), extraction/provenance/recycle (71), production requests and concurrency.

Native layout uses a scrolling List, system text styles, TextEditor minimum height rather than fixed page height, keyboard Done action, dynamic multiline labels, disabled busy inputs and a separate final alert. Production iphoneos build compiles this actual UI. No simulator/physical-device touch, clipboard permission, large-accessibility-font or keyboard/safe-area visual acceptance is claimed. Pending device checklist: small/large iPhone, landscape/iPad, largest Dynamic Type, keyboard Done and scrolling, cancel with no writes, empty/error preview, duplicate count, UID/CID confirmation, partial/unknown preserved after navigation/restart, task navigation, and clipboard read only on system paste tap.

No real 115 write, extraction, recycling, deletion or playback was authorized or performed during this feature development.
