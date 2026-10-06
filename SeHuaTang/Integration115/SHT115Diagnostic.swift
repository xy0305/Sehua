import Foundation

/// Only stage identifiers, HTTP status and numeric API codes are exposed; never response bodies.
public struct SHT115Diagnostic: Error, LocalizedError {
    public let stage: String
    public let outcome: String
    public let code: String
    public var errorDescription: String? {
        "115阶段=\(stage)，结果=\(outcome)" + (code.isEmpty ? "" : "，代码=\(code)") + (stage.hasSuffix("-read") || stage == "directory-list" ? "；读取失败不代表写入结果未知。" : "；已受理不代表下载完成，未知结果请先核对115任务，勿重复提交。")
    }
    static func apiCode(_ obj: [String: Any]) -> String {
        let value = SHT115HTTP.string(obj["errcode"] ?? obj["errno"] ?? obj["code"])
        return value.count <= 12 && !value.isEmpty && value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) ? value : ""
    }
}
