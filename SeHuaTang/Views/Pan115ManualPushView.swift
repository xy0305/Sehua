import SwiftUI
import UniformTypeIdentifiers

/// Separate from post extraction: input is local until the final explicit authorization.
struct Pan115ManualPushView: View {
    @State private var input = ""
    @State private var targetCID = SHT115Settings.load().parentCID
    @State private var targetPath = ""
    @State private var browsing = false
    @State private var busy = false
    @State private var message: String?
    private struct Approval {
        let settings: SHT115Settings
        let links: [String]
        let targetCID: String
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
                Text("独立手动记录，不关联帖子tid，不创建帖子目录。可浏览已有文件夹或明确新建。本次目标独立，不修改全局父目录。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("当前账户 UID：\(SHT115Settings.load().uid)")
                Text("本次目标：\(targetPath) · CID \(targetCID)")
                Button("浏览 / 选择目标文件夹…") { browsing = true }
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
                        authorization = Approval(settings: settings, links: links, targetCID: targetCID)
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
                Task { await push(approval.links, settings: approval.settings, targetCID: approval.targetCID) }
            }
        } message: {
            Text("账户 UID：\(authorization?.settings.uid ?? "")\n目标父目录 CID：\(authorization?.targetCID ?? "")\n共 \(authorization?.links.count ?? 0) 条有效链接。直接写入此目录，不创建新目录。")
        }
        .sheet(isPresented: $browsing) { NavigationStack { Pan115FolderBrowser(settings: SHT115Settings.load(), initialCID: targetCID) { cid, path in targetCID = cid; targetPath = path; browsing = false } } }
        .navigationBarBackButtonHidden(busy)
    }

    @MainActor private func push(_ approved: [String], settings: SHT115Settings, targetCID: String) async {
        busy = true; defer { busy = false }
        message = "阶段1/3：fresh验证本次目标路径"
        do {
            let current = SHT115Settings.load()
            guard current.cookie == settings.cookie, current.parentCID == settings.parentCID else { throw SHT115Error.accountMismatch }
            let service = try Pan115UIService.get()
            let prepared = try await service.prepareManualResource(settings: settings, targetCID: targetCID)
            resource = prepared
            message = "阶段2/3：验证签名、写前journal、单次提交；未知不重发"
            resource = try await service.submit(urls: approved, resourceID: prepared.id, settings: settings, autoExtraction: SHT115ExtractionPolicy.enabled())
            message = "阶段3/3：已受理，正在只读核验hash + CID"
            do {
                _ = try await service.inspect(resourceID: prepared.id, settings: settings, includeFiles: false)
                message = "115已确认完整受理；hash + CID只读查询完成，详情见手动记录。受理或100%均不代表实体文件可读。"
            } catch {
                message = "115已确认受理；后续只读核验失败，不重发：" + SHT115Settings.safeMessage(error)
            }
            input = ""
            ExtractBackground.kick()
        } catch {
            message = SHT115Settings.safeMessage(error)
            if let id = resource?.id, let service = try? Pan115UIService.get() {
                resource = await service.resources().first { $0.id == id }
            }
        }
    }
}

/// Explicit, paged directory navigation; no recursive account scan or implicit writes.
struct Pan115FolderBrowser: View {
    let settings: SHT115Settings
    let initialCID: String
    let select: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cid = ""
    @State private var page: SHT115Page?
    @State private var folders: [SHT115Entry] = []
    @State private var offset = 0
    @State private var busy = false
    @State private var error: String?
    @State private var name = ""
    @State private var confirming = false
    @State private var createID = UUID()
    private var path: String { page?.path.map { SHT115HTTP.string($0["name"] ?? $0["n"]) }.filter { !$0.isEmpty }.joined(separator: " / ") ?? "" }
    var body: some View {
        List {
            Section("当前路径") {
                Text(path.isEmpty ? "CID \(cid)" : path)
                Button("选择此文件夹") { select(cid, path) }.disabled(page == nil)
                Button("上一级") {
                    guard let ids = page?.path, ids.count > 1 else { return }
                    cid = SHT115HTTP.string(ids[ids.count - 2]["cid"])
                    Task { await load() }
                }.disabled(page?.path.count ?? 0 < 2)
                Button("从根目录浏览") { cid = "0"; Task { await load() } }
            }
            Section("子文件夹") {
                ForEach(folders, id: \.id) { folder in
                    Button(folder.name.isEmpty ? "CID " + folder.id : folder.name) { cid = folder.id; Task { await load() } }
                }
                if let p = page, p.entries.count == p.pageLimit, p.total.map({ offset + p.entries.count < $0 }) ?? true {
                    Button("下一页") { offset += p.entries.count; Task { await load(reset: false) } }
                }
                Button("刷新当前目录（只读）") { Task { await load() } }
            }
            Section("在当前目录新建") {
                TextField("文件夹名称", text: $name).autocorrectionDisabled()
                Button("核对名称并新建…") { createID = UUID(); confirming = true }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || page == nil)
                Text("确认后仅一次创建POST；写前保存journal，fresh路径核验。结果未知不自动重试，不修改全局父目录。").font(.footnote)
            }
            if busy { ProgressView("正在读取 / 核验") }
            if let error { Text(error).foregroundStyle(.orange) }
        }
        .disabled(busy)
        .navigationTitle("选择115目标文件夹")
        .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
        .task { cid = initialCID; await load() }
        .alert("确认新建文件夹", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("确认仅创建一次") { Task { await create() } }
        } message: { Text("父目录：\(path)\nCID：\(cid)\n名称：\(name)") }
    }
    @MainActor private func load(reset: Bool = true) async {
        busy = true; error = nil; defer { busy = false }
        if reset { offset = 0; folders = []; page = nil }
        do {
            let p = try await Pan115UIService.get().browseFolders(cid: cid, offset: offset, settings: settings)
            page = p; folders = p.entries.filter(\.isDirectory)
        } catch { self.error = SHT115Settings.safeMessage(error) }
    }
    @MainActor private func create() async {
        busy = true; error = nil; defer { busy = false }
        do {
            let r = try await Pan115UIService.get().createManualFolder(name: name, parentCID: cid, authorization: createID, settings: settings)
            guard let created = r.directoryCID else { throw SHT115Error.uncertainWrite }
            select(created, path + " / " + r.directoryName)
        } catch { self.error = SHT115Settings.safeMessage(error) }
    }
}
