import SwiftUI

/// One-shot starts once after the explicitly authorized detail button; advanced mode retains review.
struct Pan115ResourceView: View {
    let detail: ThreadDetail
    let base: URL
    var oneShot = false
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var showTasks = false
    @State private var stage = "准备"
    @State private var extractedURLs: [String] = []
    @State private var extractionNotes: [String] = []
    @State private var manualInput = ""
    @State private var includeExtracted = true
    @State private var busy = false
    @State private var extractionBusy = false
    @State private var showRebuildConfirmation = false
    @State private var rebuildAuthorization = UUID()
    @State private var requireSeparateSubmission = false
    @State private var showConfirmation = false
    @State private var message: String?
    @State private var resource: SHT115Resource?
    @State private var uncertainWrite = false
    @State private var diagnostic = "尚未读取本机诊断"

    var body: some View {
        List {
            Section("资源") {
                Text(detail.title)
                Text("tid \(detail.tid) · 当前阶段：\(stage)")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("独立手动推送 ed2k / 磁力（不关联此帖）", destination: Pan115ManualPushView())
                NavigationLink("115 设置", destination: Pan115SettingsView())
                if let resource {
                    NavigationLink {
                        Pan115TaskDetailView(resource: resource)
                    } label: {
                        Label("已记录任务 / 视频选择", systemImage: "play.rectangle")
                    }
                }
            }
            Section("只读恢复 / 脱敏诊断") {
                Text(diagnostic).font(.caption).textSelection(.enabled)
                Button("刷新本机诊断（不联网）") { Task { await loadExisting() } }
                    .disabled(busy)
                Button("只读核验目录（不提交任务）") { Task { await reconcile() } }
                    .disabled(busy || resource == nil)
                Button("已在115核对无目录，确认重建") {
                    rebuildAuthorization = UUID(); showRebuildConfirmation = true
                }
                .disabled(busy || resource?.manualRecoveryLocked == true || resource?.directoryWritePending != true || resource?.directoryCID != nil || resource?.tasks.contains(where: { [.unknown, .submitting, .accepted].contains($0.state) }) == true)
                if let resource {
                    Text(resource.directoryStatusText).font(.footnote).foregroundStyle(.orange)
                    if resource.manualRecoveryLocked {
                        Text("上次人工恢复写入结果未知：禁止再次重建，即使重新确认也不会重发。请在115核对，仅可只读核验；未找到不解除锁。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("设备内旧目录名：\(resource.directoryName)（不随诊断导出）").font(.caption).textSelection(.enabled)
                }
                ShareLink("导出脱敏诊断", item: diagnostic)
                Text("只读核验仅在CID或同tid目录身份确证后复用；找不到保留锁。不会清空任务、解除离线unknown或自动重发。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("提取结果（推送前核对）") {
                Button("重新提取链接（只读）") { Task { await extract() } }
                    .disabled(extractionBusy || busy)
                if extractionBusy { ProgressView() }
                Toggle("包含提取链接", isOn: $includeExtracted)
                    .disabled(busy || extractionBusy)
                ForEach(Array(extractedURLs.enumerated()), id: \.offset) { _, url in
                    Text(url).font(.caption).textSelection(.enabled)
                }
                if extractedURLs.isEmpty && !extractionBusy {
                    Text("暂无提取链接，可手动输入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(extractionNotes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.footnote).foregroundStyle(.orange)
                }
                Text("提取链接不保证可信、可下载或与标题一致。请核对来源、压缩包密码及版权；确认后提交到父目录 / 帖子标题_tid目录，绝不默认写入父目录。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Section("手动输入（不筛选）") {
                TextEditor(text: $manualInput)
                    .disabled(busy)
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("每行一个完整链接；保留所有非空行，不只接受磁力，也不按域名或格式过滤。服务器可能拒绝不支持的链接。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("将提交的全部链接") {
                ForEach(Array(submissionURLs.enumerated()), id: \.offset) { _, url in
                    Text(url).font(.caption).textSelection(.enabled)
                }
                Button("推送到帖子目录") { showConfirmation = true }
                    .disabled(busy || extractionBusy || submissionURLs.isEmpty || uncertainWrite)
                if busy { ProgressView() }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if uncertainWrite {
                    Text(resource?.directoryCreatedAwaitingPath == true ? "目录已明确创建，但路径尚未核验；禁止重建及离线提交。仅可只读核验，读取失败不改变创建成功证据。" : "写入结果不确定，已禁止此页再次提交。请进入本机任务详情手动刷新，并在115核对；不要盲目重试。")
                        .font(.footnote).foregroundStyle(.orange)
                    Link("在115核对", destination: URL(string: "https://115.com/")!)
                }
                Text("已有本机确证帖子CID时fresh核验复用；首次只创建一次帖子目录，不全分页枚举父目录、不预查离线任务。解压及回收必须有真实写前来源证据；读取未完成不授权。未知或冲突不自动重建、不重发。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("115 帖子目录 / 资源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if oneShot {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            guard !started else { return }
            started = true
            await loadExisting()
            if oneShot { await runOneShot() } else { await extract() }
        }
        .navigationDestination(isPresented: $showTasks) {
            if let resource { Pan115TaskDetailView(resource: resource) }
        }
        .alert("已在115核对无目录，确认重建", isPresented: $showRebuildConfirmation) {
            Button("确认：仅恢复目录", role: .destructive) { Task { await rebuildDirectory() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前父CID：\(SHT115Settings.load().parentCID)\ntid：\(detail.tid)\n设备内旧目录名：\(resource?.directoryName ?? "未知")\n完整分页仍不是事务快照，存在并发创建重复目录风险。确认后先重新全量核验，唯一目录只读复用，否则最多创建一次。结果未知不重发。不推送任何离线任务；成功后须另行确认离线推送。")
        }
        .confirmationDialog("向帖子目录提交 \(submissionURLs.count) 个链接？", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("确认推送到帖子目录") { Task { await submit() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先核对上方全部 URL 和来源警告。这会向115发起真实写入，目标为父目录 / 帖子标题_tid目录；仅提交、不等待下载、不自动播放。不搬移旧文件；缺少来源证据不授权自动回收原包。")
        }
    }

    private var submissionURLs: [String] {
        let manual = manualInput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (includeExtracted ? extractedURLs : []) + manual
    }

    @MainActor private func loadExisting() async {
        do {
            let service = try Pan115UIService.get()
            let settings = SHT115Settings.load()
            let records = await service.resources()
            let matching = records.filter { $0.account == settings.account && $0.tid == String(detail.tid) && $0.parentCID == settings.parentCID }
            resource = matching.first { $0.directInput != true && $0.manualInput != true } ?? matching.first
            diagnostic = await service.safeDiagnostic(tid: String(detail.tid), settings: settings)
            uncertainWrite = false
            if let resource {
                uncertainWrite = resource.directoryWritePending || resource.tasks.contains {
                    $0.state == .unknown || $0.state == .submitting
                }
            }
        } catch { message = "无法读取本机任务记录。" }
    }

    @MainActor private func extract() async {
        extractionBusy = true
        defer { extractionBusy = false }
        do {
            let result = try await ResourceLinkExtractor.extractResult(detail: detail, base: base)
            extractedURLs = result.links
            extractionNotes = result.resources.flatMap { link in
                link.sources.map { source in
                    "\(link.value)\n来源：\(sourceDescription(source))"
                }
            } + result.warnings.map { "\($0.attachmentName)：\($0.message)" }
            if result.usedArchiveGroup {
                extractionNotes.insert("自动提取已优先选择压缩包组；压缩包离线后仍须解压，不能直接播放。", at: 0)
            }
        } catch {
            extractedURLs = []
            if let extractionError = error as? ResourceLinkExtractor.ExtractionError,
               case .noValidLinks(let warnings) = extractionError {
                extractionNotes = warnings.map { "\($0.attachmentName)：\($0.message)" }
            } else {
                extractionNotes = ["提取失败，请检查站点登录、附件权限与网络；仍可手动输入完整链接。"]
            }
        }
    }

    private func sourceDescription(_ source: ResourceLinkExtractor.Source) -> String {
        switch source {
        case .body(let postID): return "帖子正文（post \(postID)）"
        case .detailLink: return "帖子详情中的资源链接"
        case .attachment(let name, let url): return "TXT 附件 \(name)"
        }
    }

    @MainActor private func runOneShot() async {
        if let resource, resource.directoryCID != nil,
           resource.tasks.contains(where: { $0.state == .accepted }) {
            showTasks = true
            return
        }
        guard !busy, !uncertainWrite, !requireSeparateSubmission else { return }
        stage = "提取链接"
        await extract()
        guard !extractedURLs.isEmpty else {
            message = "未提取到可提交链接，未创建目录。"
            return
        }
        if resource?.directoryRecoveryOnly == true || resource?.directoryJournal?.contains(where: { $0.manualRecovery }) == true {
            showConfirmation = true
            message = "此记录经过目录恢复；请另行确认离线推送，不会自动提交。"
            return
        }
        stage = "推送到帖子目录"
        await submit()
        if resource?.tasks.contains(where: { $0.state == .accepted }) == true { showTasks = true }
    }

    @MainActor private func rebuildDirectory() async {
        guard let resource, !busy else { return }
        busy = true; requireSeparateSubmission = true
        defer { busy = false }
        stage = "用户确认目录恢复"
        do {
            let service = try Pan115UIService.get()
            self.resource = try await service.confirmDirectoryRebuild(resourceID: resource.id, tid: String(detail.tid), settings: SHT115Settings.load(), authorization: rebuildAuthorization)
            message = "目录已核验恢复；未推送离线任务，请另行核对链接并确认归档。"
        } catch { message = SHT115Settings.safeMessage(error) }
        await loadExisting()
    }

    @MainActor private func reconcile() async {
        guard let resource, !busy else { return }
        busy = true
        defer { busy = false }
        stage = "目录只读核验"
        do {
            let settings = SHT115Settings.load()
            let service = try Pan115UIService.get()
            self.resource = try await service.reconcileDirectory(resourceID: resource.id, settings: settings)
            let inspection = try await service.inspect(resourceID: resource.id, settings: settings, includeFiles: false)
            self.resource = inspection.resource
            message = inspection.verificationSummary + "；未提交或重发，unknown锁保留。"
        } catch { message = SHT115Settings.safeMessage(error) }
        await loadExisting()
    }

    @MainActor private func submit() async {
        let urls = submissionURLs
        guard !busy, !urls.isEmpty, !uncertainWrite else { return }
        busy = true
        defer { busy = false }
        do {
            let settings = SHT115Settings.load()
            try settings.validate()
            let service = try Pan115UIService.get()
            stage = "帖子目录核验或单次创建、签名与离线提交"
            resource = try await service.createAndSubmitResource(urls: urls, tid: String(detail.tid), title: detail.title, settings: settings, autoExtraction: SHT115ExtractionPolicy.enabled())
            ExtractBackground.kick()
            message = "115已受理到父目录 / \(resource?.directoryName ?? "帖子标题_tid目录")（CID \(resource?.directoryCID ?? "待核验")），下载状态稍后更新。不搬移旧文件；解压及回收仍须来源证据。受理不等于下载完成。"
        } catch {
            // Derive locks from the durable journal, not from a broad catch:
            // a failed read/signature is not evidence that a write was sent.
            await loadExisting()
            message = "\(stage)：" + SHT115Settings.safeMessage(error)
        }
    }
}
