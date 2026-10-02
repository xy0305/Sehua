import Foundation
#if canImport(libarchive)
import libarchive
#endif

/// Reads one non-solid, unencrypted RAR/zip/7z layer from memory. Never writes the archive.
enum SmallArchiveReader {
    struct Entry {
        let path: String
        let data: Data
    }
    enum ReadError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            if case .unreadable(let message) = self { return message }
            return nil
        }
    }

    static func entries(in data: Data, maximumBytes: Int) throws -> [Entry] {
        #if canImport(libarchive)
        guard let archive = archive_read_new() else { throw ReadError.unreadable("无法创建压缩包读取器。") }
        defer { archive_read_free(archive) }
        guard archive_read_support_filter_all(archive) == ARCHIVE_OK,
              archive_read_support_format_all(archive) == ARCHIVE_OK else {
            throw ReadError.unreadable("当前构建不支持该压缩格式。")
        }
        let opened = data.withUnsafeBytes { bytes in
            archive_read_open_memory(archive, bytes.baseAddress, bytes.count)
        }
        guard opened == ARCHIVE_OK else { throw message(archive, "压缩包无法打开，请检查是否加密、分卷或不完整。") }
        var output: [Entry] = []
        var header: OpaquePointer?
        while true {
            let next = archive_read_next_header(archive, &header)
            if next == ARCHIVE_EOF { break }
            guard next == ARCHIVE_OK, let header else { throw message(archive, "压缩包目录读取失败。") }
            let rawPath = archive_entry_pathname(header).map { String(cString: $0) } ?? ""
            if archive_entry_filetype(header) == AE_IFDIR { continue }
            let size = archive_entry_size(header)
            guard size >= 0, size <= Int64(maximumBytes) else { throw ReadError.unreadable("压缩包内文件超过读取限制。") }
            var bytes = Data()
            bytes.reserveCapacity(Int(size))
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = archive_read_data(archive, &buffer, buffer.count)
                if count == 0 { break }
                guard count > 0 else { throw message(archive, "压缩包内容读取失败。") }
                bytes.append(buffer, count: count)
                guard bytes.count <= maximumBytes else { throw ReadError.unreadable("压缩包内文件超过读取限制。") }
            }
            output.append(Entry(path: rawPath, data: bytes))
        }
        return output
        #else
        throw ReadError.unreadable("当前构建没有 RAR 读取库。")
        #endif
    }

    #if canImport(libarchive)
    private static func message(_ archive: OpaquePointer, _ fallback: String) -> ReadError {
        let raw = archive_error_string(archive).map { String(cString: $0) } ?? ""
        if raw.localizedCaseInsensitiveContains("pass") || raw.localizedCaseInsensitiveContains("encrypt") {
            return .unreadable("压缩包已加密，App 内不尝试破解。")
        }
        return .unreadable(fallback)
    }
    #endif
}
