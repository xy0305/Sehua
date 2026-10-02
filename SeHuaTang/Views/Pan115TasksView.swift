import SwiftUI

struct Pan115TasksView: View {
    @State private var resources: [SHT115Resource] = []
    @State private var message: String?

    var body: some View {
        List {
            Section {
                NavigationLink("115 设置", destination: Pan115SettingsView())
                Text("仅显示本机记录；详情自动读取目录，前台有界刷新。未知写入不重发。")
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
    @Environment(\.scenePhase) private var scenePhase
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
                Text("进入页面自动读取；前台每15秒刷新，最多20轮。关闭应用停止。仅扫描本资源目录。")
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
                            Text("自动云解压到本资源目录；保留原包，不绕过密码。状态：" + (resource.extractions?[archive.id]?.rawValue ?? "等待解析"))
                                .font(.caption).foregroundStyle(.orange)
                            Link("在115核对密码或未知结果", destination: URL(string: "https://115.com/")!)
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
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh(background: true)
            for _ in 0..<20 {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard !Task.isCancelled, scenePhase == .active else { return }
                await refresh(background: true)
            }
        }
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

    @MainActor private func refresh(background: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let service = try Pan115UIService.get()
            let settings = SHT115Settings.load()
            // Publish videos before any task query or archive write can fail.
            let current = try await service.listVideos(resourceID: resource.id, settings: settings, background: background)
            listing = current
            if !current.truncated {
                for archive in current.archives.prefix(4) {
                    guard !Task.isCancelled, scenePhase == .active else { return }
                    do {
                        let outcome = try await service.requestExtraction(archive: archive, resourceID: resource.id, settings: settings, confirmed: true, background: true)
                        message = outcome.message
                    } catch { message = SHT115Settings.safeMessage(error) }
                }
            }
            let inspection = try await service.inspect(resourceID: resource.id, settings: settings, background: background)
            resource = inspection.resource
            listing = inspection.listing
            if inspection.taskPagesTruncated { message = "视频目录已读取；定向任务查询失败或达到上限，进度可能不完整。" }
        } catch { message = SHT115Settings.safeMessage(error) }
    }
}
