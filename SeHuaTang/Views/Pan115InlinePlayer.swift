import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit
import KSPlayer

/// AVDB KSPlayer, fed by the current resource directory. Episode changes replace the URL.
struct Pan115InlinePlayer: View {
    let title: String
    let videos: [SHT115Video]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showEpisodes = false
    @State private var source: SHT115PlaybackSource?
    @State private var message = "正在获取播放地址…"
    @State private var failed = false
    @State private var loadGeneration = UUID()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let source, !failed {
                KSChromePlayer(
                    url: source.url,
                    title: videos.indices.contains(index) ? videos[index].name : title,
                    subtitle: source.label,
                    headers: source.headers
                ).id(source.url)
            } else {
                VStack(spacing: 14) {
                    if !failed { ProgressView().tint(.white) }
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    if failed {
                        Button("重试") { Task { await load(index) } }
                            .foregroundStyle(.white)
                    }
                    Button("关闭") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            if source != nil, videos.count > 1, !failed {
                Button { showEpisodes = true } label: {
                    Image(systemName: "rectangle.stack.badge.play")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
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
        let generation = UUID()
        loadGeneration = generation
        index = i
        failed = false
        source = nil
        message = "正在获取第 \(i + 1) 集…"
        do {
            let service = try Pan115UIService.get()
            let sources = try await service.resolvePlayback(video: videos[i], settings: SHT115Settings.load())
            guard let first = sources.first else { throw SHT115Error.playbackUnavailable }
            guard loadGeneration == generation else { return }
            source = first
        } catch {
            guard loadGeneration == generation else { return }
            failed = true
            message = "原文件直链获取失败或无法解码，请重新获取。不会自动回退转码。"
        }
    }
}

/// Landscape KSPlayer with progress, brightness, and volume. Adapted from AVDB.
struct KSChromePlayer: View {
    let url: URL
    var title: String = ""
    var subtitle: String = ""
    var headers: [String: String] = [:]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var isPlaying = false
    @State private var isBuffering = true
    @State private var playbackFailed = false
    @State private var hasStarted = false
    @State private var showChrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var tickTask: Task<Void, Never>?
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var overlay: OverlayKind?
    @State private var overlayValue: Double = 0
    @State private var dragStart: Double = 0
    @State private var verticalDrag = false
    @State private var fillMode: FillMode = .fit

    private enum OverlayKind { case brightness, volume }
    private enum FillMode: String, CaseIterable {
        case fit = "适应屏幕"
        case fill = "填满屏幕"
        case stretch = "拉伸填满"
    }

    private var playerOptions: KSOptions {
        let options = KSOptions()
        if !headers.isEmpty { options.appendHeader(headers) }
        if let ua = headers["User-Agent"] { options.userAgent = ua }
        if let referer = headers["Referer"] { options.referer = referer }
        KSOptions.isAutoPlay = true
        options.videoAdaptable = fillMode != .stretch
        options.canStartPictureInPictureAutomaticallyFromInline = false
        return options
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let videoHeight = landscape ? geo.size.height : geo.size.width * 9 / 16
            VStack(spacing: 0) {
                videoArea(height: videoHeight, width: geo.size.width)
                if !landscape {
                    infoBar
                    Spacer(minLength: 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .background(HiddenVolumeView().frame(width: 2, height: 2).opacity(0.01))
        .onAppear {
            coordinator.isMaskShow = false
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            wireCoordinator()
            startTicker()
            scheduleHide()
            OrientationLock.set(.landscapeRight, keepLocked: true)
        }
        .onChange(of: url) { _, _ in
            hasStarted = false
            isBuffering = true
            currentTime = 0
            duration = 0
            showChrome = true
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            tickTask?.cancel()
            coordinator.playerLayer?.pause()
            OrientationLock.set(.portrait, keepLocked: true)
        }
    }

    @ViewBuilder
    private func videoArea(height: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Color.black
            KSVideoPlayer(coordinator: coordinator, url: url, options: playerOptions)
                .onAppear { applyFillMode() }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleChrome() }
                .highPriorityGesture(sideDrag(width: width, height: height))
                .padding(.top, 72)
                .padding(.bottom, 92)
                .zIndex(1)
            if playbackFailed {
                VStack(spacing: 12) {
                    Text("原文件播放失败：链接可能过期，或源容器 / 编码不受支持。未自动回退转码。")
                        .foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("返回并重新获取原文件") { dismiss() }.foregroundStyle(.white)
                }.padding(24).background(Color.black.opacity(0.9)).zIndex(30)
            } else if !hasStarted {
                ProgressView().tint(.white).scaleEffect(1.15)
                    .allowsHitTesting(false)
            }
            if let overlay {
                overlayHUD(overlay).allowsHitTesting(false)
            }
            if showChrome { chromeOverlay.zIndex(20) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }

    private func sideDrag(width: CGFloat, height: CGFloat) -> some Gesture {
        let travel = max(140, height * 0.42)
        return DragGesture(minimumDistance: 4)
            .onChanged { value in
                let dx = abs(value.translation.width)
                let dy = abs(value.translation.height)
                if !verticalDrag && overlay == nil {
                    guard dy > dx, dy > 6 else { return }
                    verticalDrag = true
                    hideTask?.cancel()
                    if value.startLocation.x < width * 0.5 {
                        overlay = .brightness
                        dragStart = UIScreen.main.brightness
                    } else {
                        overlay = .volume
                        dragStart = Double(SystemVolume.current)
                    }
                    overlayValue = dragStart
                }
                guard verticalDrag, overlay != nil else { return }
                let next = min(1, max(0, dragStart - value.translation.height / travel))
                overlayValue = next
                applyOverlay(next)
            }
            .onEnded { _ in
                verticalDrag = false
                overlay = nil
                if showChrome { scheduleHide() }
            }
    }

    private func applyOverlay(_ value: Double) {
        switch overlay {
        case .brightness: UIScreen.main.brightness = value
        case .volume: SystemVolume.set(Float(value))
        case nil: break
        }
    }

    private func overlayHUD(_ kind: OverlayKind) -> some View {
        VStack(spacing: 10) {
            Image(systemName: kind == .brightness
                  ? (overlayValue > 0.5 ? "sun.max.fill" : "sun.min.fill")
                  : (overlayValue > 0.01 ? "speaker.wave.2.fill" : "speaker.slash.fill"))
                .font(.system(size: 22, weight: .semibold))
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 6, height: 90)
                .overlay(alignment: .bottom) {
                    Capsule().fill(Color.white).frame(height: 90 * overlayValue)
                }
                .clipShape(Capsule())
            Text("\(Int(overlayValue * 100))%").font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var infoBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? "正在播放" : title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Color(white: 0.12))
    }

    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .zIndex(30)
                Text(title.isEmpty ? "正在播放" : title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    ForEach(FillMode.allCases, id: \.self) { mode in
                        Button {
                            fillMode = mode
                            applyFillMode()
                        } label: {
                            if fillMode == mode { Label(mode.rawValue, systemImage: "checkmark") }
                            else { Text(mode.rawValue) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { toggleChrome() }
            progressBar.padding(.horizontal, 16)
            HStack(spacing: 22) {
                Button {
                    if isPlaying { coordinator.playerLayer?.pause() }
                    else { coordinator.playerLayer?.play() }
                } label: {
                    Group {
                        if isBuffering { ProgressView().tint(.white) }
                        else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                Button {
                    seek(to: min((isSeeking ? seekValue : currentTime) + 10, max(duration, 0)))
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                Spacer()
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .padding(.top, 6)
        }
        .background {
            LinearGradient(
                colors: [Color.black.opacity(0.55), .clear, .clear, Color.black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            Text(formatTime(isSeeking ? seekValue : currentTime))
                .font(.caption.monospacedDigit()).foregroundStyle(.white).frame(width: 48, alignment: .leading)
            Slider(
                value: Binding(
                    get: { isSeeking ? seekValue : currentTime },
                    set: { seekValue = $0; isSeeking = true }
                ),
                in: 0...max(duration, 0.1)
            ) { editing in
                if editing { hideTask?.cancel(); isSeeking = true }
                else { seek(to: seekValue); currentTime = seekValue; isSeeking = false; scheduleHide() }
            }
            .tint(.white)
            Text(formatTime(duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.white).frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func applyFillMode() {
        guard let player = coordinator.playerLayer?.player else { return }
        switch fillMode {
        case .fit: player.contentMode = .scaleAspectFit
        case .fill: player.contentMode = .scaleAspectFill
        case .stretch: player.contentMode = .scaleToFill
        }
    }

    private func wireCoordinator() {
        coordinator.isMaskShow = false
        coordinator.onFinish = { _, error in
            guard error != nil else { return }
            Task { @MainActor in playbackFailed = true }
        }
        coordinator.onStateChanged = { _, state in
            Task { @MainActor in
                isPlaying = state.isPlaying
                isBuffering = state == .buffering || state == .preparing
                if state.isPlaying {
                    hasStarted = true
                    coordinator.playerLayer?.play()
                    applyFillMode()
                    syncTime()
                }
            }
        }
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                syncTime()
            }
        }
    }

    private func syncTime() {
        guard !isSeeking, let layer = coordinator.playerLayer else { return }
        currentTime = layer.player.currentPlaybackTime
        let value = layer.player.duration
        if value.isFinite, value > 0 { duration = value }
    }

    private func seek(to time: TimeInterval) {
        coordinator.playerLayer?.seek(time: time, autoPlay: coordinator.playerLayer?.options.isSeekedAutoPlay ?? false) { _ in }
    }

    private func formatTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func toggleChrome() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
        if showChrome { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showChrome = false }
        }
    }
}

enum OrientationLock {
    static func set(_ mask: UIInterfaceOrientationMask, keepLocked: Bool = false) {
        if UIDevice.current.userInterfaceIdiom == .pad, mask == .portrait {
            apply(.all, requestGeometry: false)
            return
        }
        apply(mask, requestGeometry: true)
        _ = keepLocked
    }

    private static func apply(_ mask: UIInterfaceOrientationMask, requestGeometry: Bool) {
        KSOptions.supportedInterfaceOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first(where: { $0.isKeyWindow })?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard requestGeometry else { return }
        DispatchQueue.main.async {
            scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}

private struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.isUserInteractionEnabled = false
        captureSlider(from: view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { captureSlider(from: view) }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) { captureSlider(from: uiView) }

    private func captureSlider(from view: UIView) {
        if let slider = findSlider(in: view) { SystemVolume.slider = slider }
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        return view.subviews.lazy.compactMap(findSlider(in:)).first
    }
}

enum SystemVolume {
    static weak var slider: UISlider?
    static var current: Float { slider?.value ?? AVAudioSession.sharedInstance().outputVolume }
    static func set(_ value: Float) {
        let value = max(0, min(1, value))
        if let slider {
            slider.setValue(value, animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }
}
