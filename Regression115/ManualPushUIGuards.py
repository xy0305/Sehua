from pathlib import Path
root = Path(__file__).resolve().parents[1]
view = (root / 'SeHuaTang/Views/Pan115ManualPushView.swift').read_text()
assert 'PasteButton(payloadType: String.self)' in view
assert 'UIPasteboard' not in view and '.onAppear' not in view and '.task' not in view
assert 'Button("清空输入", role: .destructive) { input = "" }' in view
assert 'Button("取消", role: .cancel) { authorization = nil }' in view
assert 'Approval(settings: settings, links: links)' in view
assert 'push(approval.links, settings: approval.settings)' in view
assert 'current.cookie == settings.cookie, current.parentCID == settings.parentCID' in view
assert 'busy = true\n                Task' in view
assert '.toolbar' in view and 'placement: .keyboard' in view and 'editing = false' in view
assert 'List {' in view and '.font(.footnote)' in view and '.frame(minHeight: 160)' in view
assert 'resolvePlayback' not in view and 'play(' not in view
assert 'NavigationLink("手动推送 ed2k / 磁力"' in (root / 'SeHuaTang/Views/Pan115TasksView.swift').read_text()
print('manual UI source guards: explicit paste / frozen confirmation / cancel / clear / keyboard / discoverability passed; not a device interaction test')
