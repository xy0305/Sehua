import SwiftUI

struct Pan115TasksView: View {
    @State private var resources: [SHT115Resource] = []
    @State private var message: String?

    var body: some View {
        List {
            Section {
                NavigationLink("115 设置", destination: Pan115SettingsView())
                Text("仅显示本机记录；不自动刷新或重试写入。应用关闭后不会继续轮询。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("重新读取本机记录") { Task { await load() } }
                if let message { Text(message).font(.footnote) }
            }
            Section("资源目录") {
                ForEach(resources) { resource in
                    NavigationLink {
                        Pan115TaskDetailView(resource: resource)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(resource.directoryName)
                            Text("tid \(resource.tid) · \(resource.tasks.count) 次提交")
                                .font(.caption).foregroundStyle(.secondary)
                            if resource.directoryWritePending {
                                Text("目录写入结果不确定，请在115核对，勿重复创建")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if resources.isEmpty { Text("暂无本机任务记录").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("115 资源任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
    }

    @MainActor private func load() async {
        do {
            let service = try Pan115UIService.get()
            resources = await service.resources()
            message = nil
        } catch { message = "无法读取本机任务记录。" }
    }
}

struct Pan115TaskDetailView: View {
    @State var resource: SHT115Resource
    @State private var listing: SHT115VideoListing?
    @State private var selectedArchive: SHT115Archive?
    @State private var confirmExtraction = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            Section("独立归档目录") {
                Text(resource.directoryName)
                LabeledContent("帖子 tid", value: String(resource.tid))
                LabeledContent("目录 CID", value: resource.directoryCID ?? "未确认")
                if resource.directoryWritePending {
                    Text("目录创建结果不确定，请在115核对后处理；本页面不会自动重发。")
                        .foregroundStyle(.orange)
                }
                Link("在115网页核对", destination: URL(string: "https://115.com/")!)
                Button {
                    Task { await refresh() }
                } label: {
                    HStack {
                        Label("手动刷新任务 / 目录", systemImage: "arrow.clockwise")
                        if busy { Spacer(); ProgressView() }
                    }
                }.disabled(busy)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Text("iOS 关闭应用后不持续轮询；列表只在手动刷新时读取。只查询本资源目录，不搜索整个网盘。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("提交记录") {
                ForEach(resource.tasks) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("状态：\(submissionStatus(task.state))")
                        Text(task.updatedAt, style: .date).font(.caption)
                        ForEach(Array(task.urls.enumerated()), id: \.offset) { _, url in
                            Text(url).font(.caption).textSelection(.enabled)
                        }
                        ForEach(Array(task.progress.enumerated()), id: \.offset) { _, progress in
                            Text("115 状态 \(progress.status) · \(progress.percent, specifier: "%.1f")%")
                                .font(.caption)
                        }
                        if task.progress.isEmpty {
                            Text("未匹配到进度，不代表离线完成。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("视频选择") {
                if let listing {
                    if listing.truncated {
                        Text("目录扫描达到安全上限，结果不完整；请到115核对其余文件。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    ForEach(listing.videos) { video in
                        NavigationLink {
                            Pan115VideoView(video: video)
                        } label: {
                            VStack(alignment: .leading) {
                                Label(video.name, systemImage: "play.rectangle")
                                Text(ByteCountFormatter.string(fromByteCount: video.size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if listing.videos.isEmpty {
                        Text("暂无可选视频。离线可能未完成，或资源为尚未解压的压缩包。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(listing.archives) { archive in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(archive.name, systemImage: "doc.zipper")
                            Text("压缩包不能直接播放。尚未解压；当前服务未验证完整云解压协议，不会自动解压或删除原文件。")
                                .font(.caption).foregroundStyle(.orange)
                            Button("确认检查云解压支持（不会删除原包）") {
                                selectedArchive = archive
                                confirmExtraction = true
                            }.disabled(busy)
                            Link("去115解压到本资源目录，再手动刷新", destination: URL(string: "https://115.com/")!)
                        }
                    }
                } else {
                    Text("请手动刷新获取当前目录的视频与压缩包。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("归档任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .confirmationDialog("确认检查此压缩包的云解压支持？", isPresented: $confirmExtraction, titleVisibility: .visible) {
            Button("确认检查，不删除原包") { Task { await requestExtraction() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前服务能力门控将返回不支持，不会发送解压写请求。请在115解压到该资源目录后手动刷新；不会删除原包或绕过密码。")
        }
    }

    @MainActor private func requestExtraction() async {
        guard let archive = selectedArchive, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let service = try Pan115UIService.get()
            let outcome = try await service.requestExtraction(archive: archive, resourceID: resource.id,
                settings: SHT115Settings.load(), confirmed: true)
            message = outcome.message
        } catch { message = "无法确认压缩包状态；没有执行自动解压或删除。请在115核对。" }
    }

    private func submissionStatus(_ state: SHT115SubmissionState) -> String {
        switch state {
        case .prepared: return "已准备，尚未确认提交"
        case .submitting: return "提交中，结果尚未确认"
        case .accepted: return "115已接受（不等于下载完成）"
        case .rejected: return "115已拒绝"
        case .unknown: return "写入结果未知，请在115核对，勿重复提交"
        }
    }

    @MainActor private func refresh() async {
        busy = true
        defer { busy = false }
        do {
            let service = try Pan115UIService.get()
            let inspection = try await service.inspect(resourceID: resource.id, settings: SHT115Settings.load())
            resource = inspection.resource
            listing = inspection.listing
            message = inspection.taskPagesTruncated ? "任务分页达到上限，进度可能不完整。" : "已刷新；没有执行创建、推送、解压或删除。"
        } catch { message = "刷新失败，请检查115设置与网络。未执行写入重试。" }
    }
}
