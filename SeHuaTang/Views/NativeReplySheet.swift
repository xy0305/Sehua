import SwiftUI

struct NativeReplySheet: View {
    let tid: Int
    let fid: Int?
    let title: String
    let fallbackURL: URL
    @Binding var draft: String
    let onSuccess: (NativeReplyProtocol.Success) -> Void
    @EnvironmentObject var session: WebSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = NativeReplyService.shared
    @State private var busy = false
    @State private var confirm = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.headline).lineLimit(2)
                Text("普通回复；引用、验证码和特殊表单请使用网页。取消后草稿保留在当前详情。").font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $draft).frame(minHeight: 180).disabled(busy)
                Text("\(draft.count) 字").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                if service.locked(host: session.host, tid: tid) {
                    Text("此前请求已发出但结果未知（也可能已成功、旧版未识别成功回包），本主题原生重发保持锁定。升级不会解锁。请只查看原帖确认，勿再次发布。").font(.footnote).foregroundStyle(.orange)
                }
                NavigationLink("在应用内网页查看原帖 / 处理验证") {
                    LoginWebView(url: fallbackURL, title: "原帖 / 回复验证")
                }.disabled(busy)
                Spacer()
            }
            .padding()
            .navigationTitle("回复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "发送中" : "发送") { confirm = true }
                        .disabled(busy || fid == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.locked(host: session.host, tid: tid))
                }
            }
            .confirmationDialog("确认发布这条普通回复？", isPresented: $confirm, titleVisibility: .visible) {
                Button("发布回复") { Task { await send() } }
                Button("取消", role: .cancel) {}
            }
            .interactiveDismissDisabled(busy)
        }
    }
    @MainActor private func send() async {
        guard !busy, let fid else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let result = try await service.submit(session: session, tid: tid, fid: fid, message: draft)
            draft = ""
            onSuccess(result)
            dismiss()
        } catch let error as NativeReplyProtocol.ReplyError { message = error.localizedDescription }
        catch { message = "未发送：无法取得可用回复表单，请检查网络或在网页完成登录 / 验证。草稿保留。" }
    }
}
