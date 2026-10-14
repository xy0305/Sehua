import Foundation

/// Geometry belongs to the document, not a decoded bitmap's visibility lifetime.
/// Keep only dimensions (never bytes/cookies) until this detail view is released.
@MainActor final class DetailImageLayout {
    private var ratios: [String: Double] = [:]

    static func key(url: URL?, referer: String) -> String {
        referer + "\n" + (url?.absoluteString ?? "")
    }

    func ratio(for key: String) -> Double { ratios[key] ?? 1 }

    func record(width: Double, height: Double, for key: String) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        let ratio = width / height
        guard ratio.isFinite, ratio > 0 else { return }
        // First successful decode fixes this response's geometry. Cancellation,
        // re-decode/downsampling, errors and GIF frame changes cannot shrink it.
        if ratios[key] == nil, ratios.count < 512 { ratios[key] = ratio }
    }
}
