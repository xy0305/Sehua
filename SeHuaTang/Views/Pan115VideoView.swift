import SwiftUI

struct Pan115VideoView: View {
    let video: SHT115Video
    @State private var sources: [SHT115PlaybackSource] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            Section("视频") {
                Text(video.name)
                Text("优先选择转码 HLS（m3u8）。原画仅作回退，MKV / AVI 等容器或编码不一定受原生播放器支持。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("播放源") {
                Button("获取 / 更新播放源（只读）") { Task { await load() } }
                    .disabled(busy)
                if busy { ProgressView() }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                ForEach(Array(preferredSources.enumerated()), id: \.offset) { _, source in
                    NavigationLink {
                        KSSourcePlayer(title: video.name, source: source)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(source.label, systemImage: "play.circle")
                            Text(source.url.pathExtension.lowercased() == "m3u8" ? "HLS · 优先" : "原画 / 回退 · 编码可能不兼容")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("播放请求使用服务返回的同一 UA 与认证头。不显示或保存带签名的播放 URL；地址过期请重新获取。iOS 对 HLS 子请求的认证头支持存在限制，遇到403不能保证直接播放。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("选择播放源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
    }

    private var preferredSources: [SHT115PlaybackSource] {
        sources.sorted { lhs, rhs in
            let lhls = lhs.url.pathExtension.lowercased() == "m3u8"
            let rhls = rhs.url.pathExtension.lowercased() == "m3u8"
            if lhls != rhls { return lhls }
            return lhs.bandwidth > rhs.bandwidth
        }
    }

    @MainActor private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let service = try Pan115UIService.get()
            sources = try await service.resolvePlayback(video: video, settings: SHT115Settings.load())
            message = sources.isEmpty ? "没有可用播放源；转码可能尚未完成，请稍后手动刷新。" : nil
        } catch {
            sources = []
            message = "获取播放源失败，请检查115设置、转码状态与网络。"
        }
    }
}

private struct KSSourcePlayer: View {
    let title: String
    let source: SHT115PlaybackSource
    var body: some View {
        KSChromePlayer(url: source.url, title: title, subtitle: source.label, headers: source.headers)
            .toolbar(.hidden, for: .navigationBar)
    }
}
