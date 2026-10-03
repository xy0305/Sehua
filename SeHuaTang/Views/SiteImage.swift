import SwiftUI
import UIKit
import ImageIO
import WebKit

private struct AnimatedSiteImage: UIViewRepresentable {
    let image: UIImage
    let mode: ContentMode
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = mode == .fit ? .scaleAspectFit : .scaleAspectFill
        view.image = image
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: ()) {
        view.stopAnimating()
        view.image = nil
    }
}

/// ImageIO detects the actual signature (not the URL suffix). A bounded decode
/// supports GIF and any multi-frame format the device ImageIO can decode.
enum SiteImageDecoder {
    static func decode(_ data: Data) -> UIImage? {
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let animated = count > 1 && count <= 120
        let limit = animated ? count : 1
        // Worst-case RGBA decode stays below 32 MiB for the complete animation.
        let side = animated ? min(768, Int(sqrt(Double(32 * 1024 * 1024 / (4 * limit))))) : 2048
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

struct SiteImage<Placeholder: View>: View {
    let url: URL?
    var referer: String = "https://www.sehuatang.org/"
    var contentMode: ContentMode = .fill
    // Fixed-size thumbnails/avatars use their container's geometry; only
    // document media should derive layout from decoded image dimensions.
    var preservesIntrinsicAspectRatio = true
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
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
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        image = nil
        guard let url else { return }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let cookies = await WebSession.shared.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let host = url.host ?? ""
            return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https")
        }
        for (key, value) in HTTPCookie.requestHeaderFields(with: matching) { req.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let img = await Task.detached(priority: .utility, operation: { SiteImageDecoder.decode(data) }).value else { return }
            try Task.checkCancellation()
            image = img
        } catch {
            return
        }
    }
}
