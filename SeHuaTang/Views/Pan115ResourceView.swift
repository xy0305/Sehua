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
    @State private var showConfirmation = false
    @State private var message: String?
    @State private var resource: SHT115Resource?
    @State private var uncertainWrite = false

    var body: some View {
        List {
            Section("资源") {
                Text(detail.title)
                Text("tid \(detail.tid) · 当前阶段：\(stage)")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("115 设置", destination: Pan115SettingsView())
                if let resource {
                    NavigationLink {
                        Pan115TaskDetailView(resource: resource)
                    } label: {
                        Label("已记录任务 / 视频选择", systemImage: "play.rectangle")
                    }
                }
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
                Text("提取链接不保证可信、可下载或与标题一致。请核对来源、压缩包密码及版权；只有确认后才创建目录与提交。")
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
                Button("确认归档到独立 tid 目录") { showConfirmation = true }
                    .disabled(busy || extractionBusy || submissionURLs.isEmpty || uncertainWrite)
                if busy { ProgressView() }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if uncertainWrite {
                    Text("写入结果不确定，已禁止此页再次提交。请进入本机任务详情手动刷新，并在115核对；不要盲目重试。")
                        .font(.footnote).foregroundStyle(.orange)
                    Link("在115核对", destination: URL(string: "https://115.com/")!)
                }
                Text("不会自动删除、解压或自动重试。离线完成后手动刷新选择视频；压缩包离线完成仍不能直接播放。iOS 关掉应用后不会持续轮询。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("115 归档 / 播放")
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
        .confirmationDialog("创建 / 复用此帖独立目录并提交 \(submissionURLs.count) 个链接？", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("确认创建目录并提交") { Task { await submit() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先核对上方全部 URL 和来源警告。这会向115发起真实写入操作，不执行解压或删除。")
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
            resource = records.first { $0.tid == String(detail.tid) && $0.parentCID == settings.parentCID }
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
        case .attachment(let name, let url): return "TXT 附件 \(name) · \(url.absoluteString)"
        }
    }

    @MainActor private func runOneShot() async {
        guard !busy, !uncertainWrite else { return }
        stage = "提取链接"
        await extract()
        guard !extractedURLs.isEmpty else {
            message = "未提取到可提交链接，未创建目录。"
            return
        }
        stage = "创建目录并提交离线"
        await submit()
        if resource?.tasks.contains(where: { $0.state == .accepted }) == true { showTasks = true }
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
            let created = try await service.createOrReuseResource(tid: String(detail.tid), title: detail.title, settings: settings)
            resource = created
            resource = try await service.submit(urls: urls, resourceID: created.id, settings: settings)
            message = "已记录提交结果，请进入任务详情手动刷新。任务接受不等于离线完成。"
        } catch let error as SHT115Error where error != .uncertainWrite {
            message = SHT115Settings.safeMessage(error)
        } catch {
            // A write may have reached the server even if its response was lost.
            uncertainWrite = true
            await loadExisting()
            message = "未能确认写入结果。请检查设置，并在本机任务记录与115核对；本页面不会自动重发。"
        }
    }
}
