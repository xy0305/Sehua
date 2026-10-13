import SwiftUI
import UniformTypeIdentifiers

/// Separate from post extraction: input is local until the final explicit authorization.
struct Pan115ManualPushView: View {
    @State private var input = ""
    @State private var busy = false
    @State private var message: String?
    private struct Approval {
        let settings: SHT115Settings
        let links: [String]
    }
    @State private var authorization: Approval?
    @State private var resource: SHT115Resource?
    @FocusState private var editing: Bool
    private var links: [String] { SHT115Service.uniqueResources(ResourceLinkExtractor.links(in: input)) }
    private var ed2kCount: Int { links.filter { $0.lowercased().hasPrefix("ed2k:") }.count }

    var body: some View {
        List {
            Section("手动推送到115（不播放）") {
                NavigationLink("115账户 / 父目录设置", destination: Pan115SettingsView())
                Text("独立手动记录，不关联帖子tid，不创建帖子目录。目标为当前设置的父目录本身；如需其他归档目录，请先在设置中选择并验证。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("当前账户 UID：\(SHT115Settings.load().uid)")
                Text("目标 CID：\(SHT115Settings.load().parentCID)")
                Text("请确认账户与目标目录；提交前还会重新校验真实路径。")
                    .font(.footnote).foregroundStyle(.orange)
            }.disabled(busy)
            Section("输入 / 粘贴 ed2k 或磁力链接") {
                TextEditor(text: $input)
                    .frame(minHeight: 160).focused($editing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("手动推送链接，多行输入")
                PasteButton(payloadType: String.self) { strings in
                    input += (input.isEmpty ? "" : "\n") + strings.joined(separator: "\n")
                }
                Button("清空输入", role: .destructive) { input = "" }
                Text("可粘贴多行混合文本；仅提取有效 ed2k / magnet，按资源哈希去重（改名 / tracker变体不增加数量），不优先筛选压缩包。HTTP分享链接、密码分享和非法类型不提交、不猜密码。最多50条。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.disabled(busy)
            Section("有效链接预览：\(links.count) 条 · ed2k \(ed2kCount) · 磁力 \(links.count - ed2kCount)") {
                if links.isEmpty { Text(input.isEmpty ? "请输入或粘贴链接" : "未发现有效链接；仅支持ed2k和磁力，请检查格式。") }
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Text(link).font(.footnote).textSelection(.enabled)
                }
                if links.count > 50 { Text("超过50条，请拆分后再确认。").foregroundStyle(.red) }
            }
            Section {
                Button("核对并确认推送…") {
                    editing = false
                    do {
                        let settings = SHT115Settings.load()
                        try settings.validate()
                        authorization = Approval(settings: settings, links: links)
                    } catch { message = SHT115Settings.safeMessage(error) }
                }.disabled(busy || links.isEmpty || links.count > 50)
                if busy { ProgressView("正在验证 / 提交；请勿重复操作") }
                if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                if let resource {
                    NavigationLink("查看手动记录 / 只读核验", destination: Pan115TaskDetailView(resource: resource))
                }
                Text("未知或部分受理保留锁，不重发；已受理链接不重复推送。自动解压遵循已有全局开关，仅完整快照与逐项来源身份可证明时入队；未知、历史或来源不明文件不处理。输入不写日志或诊断导出。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("手动推送").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { editing = false } }
        }
        .alert("确认手动推送（不播放）", isPresented: Binding(get: { authorization != nil }, set: { if !$0 { authorization = nil } })) {
            Button("取消", role: .cancel) { authorization = nil }
            Button("确认推送") {
                guard let approval = authorization, !busy else { return }
                authorization = nil
                busy = true
                Task { await push(approval.links, settings: approval.settings) }
            }
        } message: {
            Text("账户 UID：\(authorization?.settings.uid ?? "")\n目标父目录 CID：\(authorization?.settings.parentCID ?? "")\n共 \(authorization?.links.count ?? 0) 条有效链接。直接写入此目录，不创建新目录。")
        }
        .navigationBarBackButtonHidden(busy)
    }

    @MainActor private func push(_ approved: [String], settings: SHT115Settings) async {
        busy = true; defer { busy = false }
        do {
            let current = SHT115Settings.load()
            guard current.cookie == settings.cookie, current.parentCID == settings.parentCID else { throw SHT115Error.accountMismatch }
            let service = try Pan115UIService.get()
            let prepared = try await service.prepareManualResource(settings: settings)
            resource = prepared
            resource = try await service.submit(urls: approved, resourceID: prepared.id, settings: settings, autoExtraction: SHT115ExtractionPolicy.enabled())
            input = ""
            message = "115已确认完整受理；不代表下载完成，未自动播放。"
            ExtractBackground.kick()
        } catch {
            message = SHT115Settings.safeMessage(error)
            if let id = resource?.id, let service = try? Pan115UIService.get() {
                resource = await service.resources().first { $0.id == id }
            }
        }
    }
}
