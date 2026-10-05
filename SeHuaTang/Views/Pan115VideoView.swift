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
                Text("仅使用115原文件下载直链，不以转码HLS冒充原画。KSPlayer尝试解码源容器；不支持时明确报错，不自动降级。")
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
                            Text(source.url.pathExtension.lowercased() == "m3u8" ? "转码 HLS" : "原文件 · 优先 · 编码可能不兼容")
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
            if lhls != rhls { return !lhls }
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
            message = "原文件直链获取或鉴权失败，请检查115设置、网络后重新获取；不会自动使用转码。"
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
