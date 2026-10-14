import SwiftUI
import UIKit
import ImageIO
import WebKit

private final class LifecycleImageView: UIImageView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopAnimating() }
        else if image?.images != nil { startAnimating() }
    }
}

private struct AnimatedSiteImage: UIViewRepresentable {
    let image: UIImage
    let mode: ContentMode
    func makeUIView(context: Context) -> UIImageView {
        let view = LifecycleImageView()
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = mode == .fit ? .scaleAspectFit : .scaleAspectFill
        if view.image !== image {
            view.stopAnimating()
            view.image = image
        }
        if view.window != nil, image.images != nil { view.startAnimating() }
        else { view.stopAnimating() }
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: ()) {
        view.stopAnimating()
        view.image = nil
    }
}

/// ImageIO detects the actual signature (not the URL suffix). A bounded decode
/// supports GIF and any multi-frame format the device ImageIO can decode.
enum SiteImageDecoder {
    static func decode(_ data: Data, animationBudget: Int = 32 * 1024 * 1024) -> UIImage? {
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let animated = count > 1 && count <= 120
        let limit = animated ? count : 1
        // Worst-case RGBA decode stays below 32 MiB for the complete animation.
        let side = animated ? min(768, Int(sqrt(Double(min(32 * 1024 * 1024, max(1024, animationBudget)) / (4 * limit))))) : 2048
        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<limit {
            if Task.isCancelled { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            frames.append(UIImage(cgImage: cg))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            duration += max(0.02, min(delay, 10))
        }
        return animated ? UIImage.animatedImage(with: frames, duration: duration) : frames.first
    }
}

/// One ImageIO job at a time across visible images. The actor never suspends
/// during decode, so GIF budgets cannot multiply with an unbounded task burst.
/// UIImage is constructed privately then handed off immutably to the main actor.
private actor SiteImageDecodeQueue {
    static let shared = SiteImageDecodeQueue()
    func decode(_ data: Data, animationBudget: Int) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return SiteImageDecoder.decode(data, animationBudget: animationBudget)
    }
}

struct SiteImage<Placeholder: View>: View {
    let url: URL?
    var referer: String = "https://www.sehuatang.org/"
    var contentMode: ContentMode = .fill
    // Fixed-size thumbnails/avatars use their container's geometry; only
    // document media should derive layout from decoded image dimensions.
    var preservesIntrinsicAspectRatio = true
    var animationBudget = 32 * 1024 * 1024
    // The detail owns this lightweight cache across lazy row destruction.
    var documentLayout: DetailImageLayout? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    private var layoutKey: String { DetailImageLayout.key(url: url, referer: referer) }

    var body: some View {
        Group {
            if let documentLayout, preservesIntrinsicAspectRatio {
                // An unloaded/cancelled/offscreen bitmap must occupy exactly the
                // last decoded rectangle. Overlay prevents placeholder intrinsic
                // height (120pt in the detail) from changing the scroll extent.
                Color.clear
                    .aspectRatio(documentLayout.ratio(for: layoutKey), contentMode: .fit)
                    .overlay {
                        if let image { AnimatedSiteImage(image: image, mode: contentMode) }
                        else { placeholder() }
                    }
                    .clipped()
            } else if let image {
                if preservesIntrinsicAspectRatio {
                    AnimatedSiteImage(image: image, mode: contentMode)
                        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: contentMode)
                } else {
                    AnimatedSiteImage(image: image, mode: contentMode)
                }
            } else {
                placeholder()
            }
        }
        .task(id: layoutKey) { await load() }
        // Release RGBA/GIF frames; document geometry deliberately survives.
        .onDisappear { image = nil }
    }

    @MainActor
    private func load() async {
        image = nil
        guard let url else { return }
        do {
            let data = try await SiteImageNetwork.shared.data(url: url, referer: referer)
            guard let img = await SiteImageDecodeQueue.shared.decode(data, animationBudget: animationBudget) else { return }
            try Task.checkCancellation()
            documentLayout?.record(width: Double(img.size.width), height: Double(img.size.height), for: layoutKey)
            image = img
        } catch {
            return
        }
    }
}
