import SwiftUI
import AVKit
import AVFoundation

/// HTTP headers must match the service request that obtained the playback URL.
/// Never show, persist or log playback URLs/headers: they can carry credentials.
@MainActor
struct Pan115NativePlayerView: View {
    let title: String
    @StateObject private var playback: Pan115NativePlayback

    init(title: String, url: URL, headers: [String: String]) {
        self.title = title
        _playback = StateObject(wrappedValue: Pan115NativePlayback(url: url, headers: headers))
    }

    var body: some View {
        VStack(spacing: 12) {
            VideoPlayer(player: playback.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if playback.failed {
                Text("视频无法播放或地址已过期。返回视频列表重新获取地址；原画编码可能不受 AVPlayer 支持，请优先选择转码 HLS。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            Text("使用原生 AVPlayer；播放链接按需获取，不写入任务记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { playback.player.play() }
        .onDisappear { playback.player.pause() }
    }
}

@MainActor
private final class Pan115NativePlayback: ObservableObject {
    let player: AVPlayer
    @Published var failed = false
    private var observation: NSKeyValueObservation?

    init(url: URL, headers: [String: String]) {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor [weak self] in self?.failed = failed }
        }
    }
}
