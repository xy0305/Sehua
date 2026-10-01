import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var categories: [ForumCategory] = BuiltinForums.categories
    @Published var forumState: LoadState = .idle

    @Published var threads: [ThreadItem] = []
    @Published var threadTypes: [ThreadType] = []
    @Published var threadPage = 1
    @Published var threadHasNext = false
    @Published var threadState: LoadState = .idle
    @Published var currentFID: Int?
    @Published var currentTypeID: Int = 0
    @Published var currentOrder = "dateline"
    @Published var boardTitle = ""

    @Published var searchHits: [SearchHit] = []
    @Published var searchState: LoadState = .idle
    @Published var portal = PortalPage(notices: [], sections: [])
    @Published var portalState: LoadState = .idle

    private struct ThreadRequest: Equatable {
        let fid: Int
        let page: Int
        let typeID: Int
        let order: String
        let append: Bool
    }
    private var activeThreadRequest: ThreadRequest?
    private var threadGeneration = UUID()
    private var forumGeneration = UUID()
    private var portalGeneration = UUID()
    private var searchGeneration = UUID()

    func loadForums() async {
        guard forumState != .loading, !Task.isCancelled else { return }
        let generation = UUID()
        forumGeneration = generation
        forumState = .loading
        do {
            let html = try await WebSession.shared.fetchHTML("forum.php?forumlist=1&mobile=2")
            guard forumGeneration == generation else { return }
            try Task.checkCancellation()
            if DiscuzParser.looksLikeChallenge(html) {
                forumState = .failed("需要过验证，请到「我的」打开网页登录")
                return
            }
            let cats = DiscuzParser.parseForumList(html)
            categories = cats
            forumState = .idle
        } catch {
            guard forumGeneration == generation else { return }
            forumState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    func loadThreads(fid: Int, page: Int = 1, typeid: Int = 0, order: String = "dateline", append: Bool = false) async {
        guard !Task.isCancelled else { return }
        let request = ThreadRequest(fid: fid, page: page, typeID: typeid, order: order, append: append)
        // Coalesce repeated last-row appearances / identical refreshes before suspension.
        guard activeThreadRequest != request else { return }
        if append {
            guard activeThreadRequest == nil, threadHasNext,
                  currentFID == fid, currentTypeID == typeid, currentOrder == order,
                  page == threadPage + 1 else { return }
        }
        let generation = UUID()
        threadGeneration = generation
        activeThreadRequest = request
        defer {
            if threadGeneration == generation { activeThreadRequest = nil }
        }
        let sameSelection = currentFID == fid && currentTypeID == typeid && currentOrder == order
        threadState = .loading
        // Refresh the same list in place. Failed refreshes keep usable old data.
        if !append && !sameSelection {
            threads = []
            threadTypes = []
            threadPage = 0
            threadHasNext = false
            boardTitle = ""
        }
        currentFID = fid
        currentTypeID = typeid
        currentOrder = order
        var path = "forum.php?mod=forumdisplay&fid=\(fid)&page=\(page)&mobile=2&orderby=\(order)"
        if typeid > 0 {
            path += "&filter=typeid&typeid=\(typeid)"
        }
        do {
            let html = try await WebSession.shared.fetchHTML(path)
            guard threadGeneration == generation else { return }
            try Task.checkCancellation()
            if DiscuzParser.looksLikeChallenge(html) {
                threadState = .failed("需要过验证")
                return
            }
            let parsed = DiscuzParser.parseThreadList(html, fid: fid, page: page)
            if append {
                var seen = Set(threads.map(\.id))
                threads.append(contentsOf: parsed.threads.filter { seen.insert($0.id).inserted })
            } else {
                var seen = Set<Int>()
                threads = parsed.threads.filter { seen.insert($0.id).inserted }
            }
            threadTypes = parsed.types
            threadPage = page
            threadHasNext = parsed.hasNext
            if !parsed.boardName.isEmpty { boardTitle = parsed.boardName }
            threadState = .idle
        } catch {
            guard threadGeneration == generation else { return }
            threadState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard let fid = currentFID, threadHasNext, threadState != .loading else { return }
        await loadThreads(fid: fid, page: threadPage + 1, typeid: currentTypeID, order: currentOrder, append: true)
    }

    func loadPortal() async {
        guard portalState != .loading, !Task.isCancelled else { return }
        let generation = UUID()
        portalGeneration = generation
        portalState = .loading
        do {
            let base = WebSession.shared.baseURL
            let html = try await WebSession.shared.fetchHTML("portal.php?mod=index&mobile=2")
            guard portalGeneration == generation else { return }
            try Task.checkCancellation()
            if DiscuzParser.looksLikeChallenge(html) {
                portalState = .failed("需要过验证，请到「我的」打开网页登录")
                return
            }
            portal = DiscuzParser.parsePortal(html, base: base)
            portalState = .idle
        } catch {
            guard portalGeneration == generation else { return }
            portalState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    func search(_ q: String) async {
        guard !Task.isCancelled else { return }
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = UUID()
        searchGeneration = generation
        guard !trimmed.isEmpty else {
            searchHits = []
            searchState = .idle
            return
        }
        searchState = .loading
        searchHits = []
        // Query values must not treat &, +, # or = as separators.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        let path = "search.php?mod=forum&searchsubmit=yes&srchtxt=\(encoded)&mobile=2"
        do {
            let html = try await WebSession.shared.fetchHTML(path)
            guard searchGeneration == generation else { return }
            try Task.checkCancellation()
            if DiscuzParser.looksLikeChallenge(html) {
                searchState = .failed("需要过验证，请到「我的」打开网页登录")
                return
            }
            searchHits = DiscuzParser.parseSearch(html)
            searchState = .idle
        } catch {
            guard searchGeneration == generation else { return }
            searchState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }
}
