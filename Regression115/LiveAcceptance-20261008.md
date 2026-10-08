# 115 live acceptance — 2026-10-08

Authorized scope: tid 3818209, existing isolated CID 3535200293442553007 under parent 3446865472442596828. No extra directory, purchase, deletion, move, lock clearing, or resend.

Actual writes across the entire test: directory create 1 (previous run), single add_task_url 1 (previous run), add_task_urls 1 (this run; resource indices 1,2). Total POSTs 3; submitted resources 3/7; remaining 4 unsubmitted.

Both new lowercase hash preflights returned HTTP 200/state true/count 0/page_count 0/matches 0. Existing directory path was verified before POST. Independent batch-testjournal was persisted before dispatch. POST HTTP 200 has state true, errno 0, errcode 0 and result[2]. Each row has state true, errcode 0, errno 0, info_hash, url, errtype empty. In-memory comparison confirmed each returned URL and lowercase hash matched its input. No secrets or actual URLs persisted.

Read-only GET for each of three submitted resources found exactly one task matching lowercase hash and target CID; status 2, percentDone 100. Official files API returned HTTP 200/state true, path matching isolated CID and parent, and three entity rows. Each original attachment filename and byte size matched exactly one row in target CID, with fid and SHA present. Task file_id did NOT equal entity fid: do not equate these identifiers or claim that equality. Entity identity is verified independently by exact source filename + exact byte size + target CID, with task hash/CID verification separate. All TLS verification remained enabled.

Root cause already fixed on this branch: accepted directory acknowledgement must survive subsequent GET failure, and accepted offline submission must survive read failures. This does not prove the cause of an older unknown-CID journal. Unknown/manual-recovery UI safeguards and persistent staged diagnostics remain unchanged.

New hardening: batch top-level state/errcode without complete per-item rows is unknown; errcode 0 alone is never success; mixed, missing and malformed rows remain unknown with no resend. Complete accepted rows must correspond to the actual unique input URLs. Regression adds real sanitized batch schema, single entity evidence, partial/zero-code/duplicate/mismatched batch cases. Real single/batch and directory acceptance do not depend on playback. Playback and physical-device acceptance are not tested.
