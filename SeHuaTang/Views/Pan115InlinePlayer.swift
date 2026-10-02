import SwiftUI
import AVKit
import AVFoundation

/// Full-screen player. Episode changes replace the item; they do not open another page.
struct Pan115InlinePlayer: View {
    let title: String
    let videos: [SHT115Video]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = Pan115InlinePlayback()
    @State private var index = 0
    @State private var showEpisodes = false
    @State private var message = "正在获取播放地址…"
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if playback.ready, !failed {
                VideoPlayer(player: playback.player).ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    if !failed { ProgressView().tint(.white) }
                    Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                    if failed { Button("重试") { Task { await load(index) } }.foregroundStyle(.white) }
                }
            }
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
                }.buttonStyle(.plain)
                Text(title).font(.caption).foregroundStyle(.white).lineLimit(1)
                Spacer()
                if videos.count > 1 {
                    Button { showEpisodes = true } label: {
                        Image(systemName: "rectangle.stack.badge.play").font(.title3.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.top, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load(0) }
        .confirmationDialog("选择集数", isPresented: $showEpisodes, titleVisibility: .visible) {
            ForEach(Array(videos.enumerated()), id: \.element.id) { i, video in
                Button(episodeTitle(i, video.name)) { Task { await load(i) } }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func episodeTitle(_ i: Int, _ name: String) -> String {
        let lower = name.lowercased()
        var marks: [String] = []
        if lower.contains("4k") || lower.contains("2160") { marks.append("4K") }
        if lower.contains("-c") || lower.contains("中字") || lower.contains("中文") { marks.append("-c") }
        let base = "第 \(i + 1) 集"
        return marks.isEmpty ? base : base + "  " + marks.joined(separator: " ")
    }

    @MainActor private func load(_ i: Int) async {
        guard videos.indices.contains(i) else { return }
        index = i
        failed = false
        playback.ready = false
        message = "正在获取第 \(i + 1) 集…"
        do {
            let service = try Pan115UIService.get()
            let sources = try await service.resolvePlayback(video: videos[i], settings: SHT115Settings.load())
            guard let first = sources.first else { throw SHT115Error.playbackUnavailable }
            playback.play(first)
        } catch {
            failed = true
            message = "无法播放。转码可能未完成，或原画容器不受系统播放器支持。"
        }
    }
}

@MainActor
private final class Pan115InlinePlayback: ObservableObject {
    let player = AVPlayer()
    @Published var ready = false
    func play(_ source: SHT115PlaybackSource) {
        let asset = AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        ready = true
        player.play()
    }
}
