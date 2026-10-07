import Foundation
import CryptoKit

public enum SHT115Error: Error, LocalizedError {
    case invalidSettings, invalidInput, busy, unsafeListing, ambiguousDirectory
    case rejected, uncertainWrite, persistence, playbackUnavailable, accountMismatch, alreadySubmitted
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: return "请配置含 UID/CID/SEID 的115 Cookie与数字父目录CID"
        case .alreadySubmitted: return "此链接已有提交记录，请进入任务 / 视频页查看，不会重复推送"
        case .invalidInput: return "资源ID、链接或目录输入无效"
        case .busy: return "已有操作执行中，请稍后手动刷新"
        case .unsafeListing: return "目录分页或路径无法完整验证，已停止写入"
        case .ambiguousDirectory: return "存在多个同名目录，已停止写入"
        case .rejected: return "115明确拒绝操作，请检查登录、配额或验证码"
        case .uncertainWrite: return "写入结果未知，禁止重发；请在115核对后手动刷新"
        case .persistence: return "本地任务记录无法安全保存，已停止后续写入"
        case .playbackUnavailable: return "暂无可用播放源，可能尚未完成转码"
        case .accountMismatch: return "当前账号与归档记录不匹配"
        }
    }
}
public struct SHT115Settings {
    public let cookie: String
    public let parentCID: String
    public init(cookie: String, parentCID: String) {
        self.cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "Cookie:", with: "", options: .anchored).trimmingCharacters(in: .whitespacesAndNewlines)
        self.parentCID = parentCID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        Self(cookie: defaults.string(forKey: "avdb.115.cookie") ?? "", parentCID: defaults.string(forKey: "avdb.115.folderCID") ?? "")
    }
    public func validate() throws {
        let keys = Set(cookie.split(separator: ";").compactMap { part -> String? in
            let p = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, !p[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return p[0].trimmingCharacters(in: .whitespaces)
        })
        guard keys.isSuperset(of: ["UID", "CID", "SEID"]), !cookie.contains("\n"), !cookie.contains("\r"), Self.isCID(parentCID) else { throw SHT115Error.invalidSettings }
    }
    public static func isCID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && (value == "0" || !value.hasPrefix("0"))
    }
    var uid: String {
        cookie.split(separator: ";").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("UID=") }
            .map { String($0.trimmingCharacters(in: .whitespaces).dropFirst(4)).components(separatedBy: "_").first ?? "" } ?? ""
    }
    var account: String { SHT115Digest(uid) }
    /// Never render arbitrary transport errors or server bodies (may contain credentials).
    public static func safeMessage(_ error: Error) -> String {
        (error as? SHT115Diagnostic)?.errorDescription ?? (error as? SHT115Error)?.errorDescription ?? "请求失败，请检查网络与登录；未确认提交前不会锁定重试。"
    }
}
func SHT115Digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
public enum SHT115SubmissionState: String, Codable { case prepared, submitting, accepted, rejected, unknown }
public struct SHT115Task: Codable, Identifiable {
    public let id: UUID
    public let urls: [String]
    public var state: SHT115SubmissionState
    public var progress: [SHT115Progress]
    public var updatedAt: Date
}
public struct SHT115Progress: Codable {
    public let url: String
    public let infoHash: String
    public let status: Int
    public let percent: Double
}
public struct SHT115Resource: Codable, Identifiable {
    public let id: String
    public let account: String
    public let tid: String
    public let directoryName: String
    public let parentCID: String
    public var directoryCID: String?
    public var directoryWritePending: Bool
    public var tasks: [SHT115Task]
    public var directoryRecoveryOnly: Bool? = nil
    public var directoryJournal: [SHT115DirectoryAttempt]? = nil
    public var extractions: [String: SHT115ExtractionState]? = nil
    public var extractionJobs: [String: SHT115ExtractionJob]? = nil
}
public struct SHT115Video: Codable, Identifiable {
    public let id: String
    public let resourceID: String
    public let directoryCID: String
    public let name: String
    public let pickCode: String
    public let size: Int64
}
public enum SHT115ExtractionState: String, Codable { case awaitingConfirmation, unsupported, parsing, submitting, accepted, rejected, unknown, passwordRequired }
public struct SHT115ExtractionResult {
    public let state: SHT115ExtractionState
    public let message: String
}
public struct SHT115Archive: Codable, Identifiable {
    public let id: String
    public let name: String
    public let directoryCID: String
    public var pickCode: String? = nil
}
public struct SHT115VideoListing {
    public let videos: [SHT115Video]
    public let archives: [SHT115Archive]
    public let truncated: Bool
}
public struct SHT115Inspection {
    public let resource: SHT115Resource
    public let listing: SHT115VideoListing
    public let taskPagesTruncated: Bool
}
public struct SHT115PlaybackSource {
    public let label: String
    public let url: URL
    public let bandwidth: Int
    /// Contains credentials; do not print or persist. Use same headers in AVURLAsset.
    public let headers: [String: String]
}

// Optional persisted metadata keeps old records readable. No metadata => no cleanup.
public struct SHT115ExtractionOutput: Codable {
    public let name: String
    public let directory: Bool
    public let size: Int64
}
public struct SHT115ExtractionJob: Codable {
    public let extractID: String
    public let source: SHT115Archive
    public let targetCID: String
    public let outputs: [SHT115ExtractionOutput]
    public let priorIDs: [String]
    public var cleanup: SHT115CleanupState
}
public enum SHT115CleanupState: String, Codable { case waiting, submitting, recycled, rejected, unknown }

/// No names, credentials or resource URLs in the creation journal.
public struct SHT115DirectoryAttempt: Codable {
    public let authorization: UUID
    public let authorizedAt: Date
    public let manualRecovery: Bool
    public let historicalPending: Bool
    public var state: SHT115SubmissionState
}
