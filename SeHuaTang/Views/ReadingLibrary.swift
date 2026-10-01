import SwiftUI

/// 本机记录，不与论坛服务器收藏混同。
@MainActor
final class ReadingLibrary: ObservableObject {
    static let shared = ReadingLibrary()
    struct Entry: Codable, Identifiable {
        let id: Int
        var title: String
        var author: String
        var dateText: String
        var coverURL: URL?
        var visitedAt: Date
        var item: ThreadItem {
            ThreadItem(id: id, title: title, excerpt: "", author: author, authorID: nil, avatarURL: nil, coverURL: coverURL, dateText: dateText, replies: "", likes: "", views: "", isSticky: false, fid: nil)
        }
    }
    @Published private(set) var history: [Entry] = []
    @Published private(set) var favorites: [Entry] = []
    private let defaults = UserDefaults.standard
    private init() {
        history = Self.read("reading.history.v1")
        favorites = Self.read("reading.favorites.v1")
    }
    private static func read(_ key: String) -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
    private func entry(_ item: ThreadItem) -> Entry {
        Entry(id: item.id, title: item.title, author: item.author, dateText: item.dateText, coverURL: item.coverURL, visitedAt: Date())
    }
    func record(_ item: ThreadItem) {
        history.removeAll { $0.id == item.id }
        history.insert(entry(item), at: 0)
        history = Array(history.prefix(300))
        save()
    }
    func isFavorite(_ id: Int) -> Bool { favorites.contains { $0.id == id } }
    func toggleFavorite(_ item: ThreadItem) {
        if isFavorite(item.id) { favorites.removeAll { $0.id == item.id } }
        else { favorites.insert(entry(item), at: 0) }
        save()
    }
    func clearHistory() { history = []; save() }
    func removeFavorite(_ id: Int) { favorites.removeAll { $0.id == id }; save() }
    private func save() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "reading.history.v1") }
        if let data = try? JSONEncoder().encode(favorites) { defaults.set(data, forKey: "reading.favorites.v1") }
    }
}

struct ReadingLibraryView: View {
    let isHistory: Bool
    @ObservedObject private var library = ReadingLibrary.shared
    @State private var confirmClear = false
    private var entries: [ReadingLibrary.Entry] { isHistory ? library.history : library.favorites }
    var body: some View {
        List {
            Section {
                Text(isHistory ? "最近阅读的帖子，仅保存在这台设备。" : "本机收藏，不与论坛账号收藏同步。可在帖子页点击星标添加。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                ContentUnavailableView(isHistory ? "还没有阅读记录" : "还没有本机收藏", systemImage: isHistory ? "clock.arrow.circlepath" : "star")
            }
            ForEach(entries) { entry in
                NavigationLink {
                    ThreadDetailView(tid: entry.id, title: entry.title)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.title).font(.headline).lineLimit(3)
                        if !entry.author.isEmpty { Text(entry.author).font(.caption).foregroundStyle(.secondary) }
                        if isHistory { Text(entry.visitedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }
                .swipeActions {
                    if !isHistory { Button("移除", role: .destructive) { library.removeFavorite(entry.id) } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isHistory ? "历史" : "收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isHistory && !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { Button("清空") { confirmClear = true } }
            }
        }
        .confirmationDialog("清空这台设备的阅读历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空历史", role: .destructive) { library.clearHistory() }
        }
    }
}
