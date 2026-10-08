import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var categories: [ForumCategory] = BuiltinForums.categories
    @Published var forumState: LoadState = .idle

    @Published var threads: [ThreadItem] = []
    @Published var threadTypes: [ThreadType] = []
    // threadPage is the last accumulated page; selected page is the range start.
    @Published var threadPage = 1
    @Published var threadSelectedPage = 1
    @Published var threadTotalPages: Int?
    @Published var threadReplacementRevision = 0
    @Published var threadPageError: String?

    func validateThreadPage(_ page: Int) -> String? {
        if page < 1 { return "页码必须是大于零的整数" }
        if let total = threadTotalPages, page > total { return "页码不能超过 \(total)" }
        return nil
    }

    func selectThreadPage(_ page: Int) async {
        guard let fid = currentFID, threadState != .loading else { return }
        if let error = validateThreadPage(page) { threadPageError = error; return }
        threadPageError = nil
        await loadThreads(fid: fid, page: page, typeid: currentTypeID, order: currentOrder)
    }
    @Published var threadHasNext = false
    @Published var threadState: LoadState = .idle
    @Published var currentFID: Int?
    @Published var currentTypeID: Int = 0
    @Published var currentOrder = "dateline"
    @Published var boardTitle = ""

    @Published var searchHits: [SearchHit] = []
    @Published var searchState: LoadState = .idle
    @Published var searchPage = 1
    @Published var searchHasNext = false
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
    private var failedThreadRequest: ThreadRequest?

    func retryThreadRequest() async {
        guard let request = failedThreadRequest else { return }
        await loadThreads(fid: request.fid, page: request.page, typeid: request.typeID,
                          order: request.order, append: request.append)
    }
    private var threadGeneration = UUID()
    private var forumGeneration = UUID()
    private var portalGeneration = UUID()
    private var searchGeneration = UUID()
    private var searchQuery = ""
    private var searchNextURL: URL?
    private var visitedSearchURLs = Set<URL>()

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
        guard !Task.isCancelled, page > 0 else { return }
        let sameContext = currentFID == fid && currentTypeID == typeid && currentOrder == order
        if sameContext, let total = threadTotalPages, page > total {
            threadPageError = "页码不能超过 \(total)"
            return
        }
        threadPageError = nil
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
        failedThreadRequest = request
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
            threadSelectedPage = 1
            threadTotalPages = nil
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
            if let total = parsed.totalPages, page > total {
                threadTotalPages = total
                threadState = .failed("页码超出范围，当前共 \(total) 页")
                return
            }
            if append {
                var seen = Set(threads.map(\.id))
                threads.append(contentsOf: parsed.threads.filter { seen.insert($0.id).inserted })
            } else {
                var seen = Set<Int>()
                threads = parsed.threads.filter { seen.insert($0.id).inserted }
            }
            if !append {
                threadSelectedPage = page
                threadReplacementRevision += 1
            }
            threadTotalPages = parsed.totalPages
            threadTypes = parsed.types
            threadPage = page
            threadHasNext = parsed.hasNext
            failedThreadRequest = nil
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
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchGeneration = UUID()
            searchQuery = ""
            searchNextURL = nil
            visitedSearchURLs = []
            searchHits = []
            searchPage = 1
            searchHasNext = false
            searchState = .idle
            return
        }
        await loadSearch(trimmed, page: 1, append: false)
    }

    func loadMoreSearch() async {
        guard searchHasNext, searchState == .idle, !searchQuery.isEmpty,
              let next = searchNextURL, let page = HTML.queryInt("page", in: next.absoluteString) else { return }
        await loadSearch(searchQuery, page: page, append: true)
    }

    func retrySearch() async {
        guard searchState != .loading, !searchQuery.isEmpty else { return }
        let append = searchNextURL != nil && !searchHits.isEmpty
        let page = append ? (HTML.queryInt("page", in: searchNextURL!.absoluteString) ?? 1) : 1
        await loadSearch(searchQuery, page: page, append: append)
    }

    private func loadSearch(_ query: String, page: Int, append: Bool) async {
        guard !Task.isCancelled else { return }
        let generation = append ? searchGeneration : UUID()
        searchGeneration = generation
        searchQuery = query
        searchState = .loading
        if !append {
            searchNextURL = nil
            visitedSearchURLs = []
            searchPage = 1
            searchHasNext = false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let firstPath = "search.php?mod=forum&searchsubmit=yes&srchtxt=\(encoded)&mobile=2"
        guard !append || searchNextURL != nil else { return }
        let target = append ? searchNextURL! : WebSession.shared.url(firstPath)
        do {
            let html = try await WebSession.shared.fetchHTML(target.absoluteString)
            guard searchGeneration == generation else { return }
            try Task.checkCancellation()
            if DiscuzParser.looksLikeChallenge(html) {
                searchState = .failed("需要过验证，请到「我的」打开网页登录")
                return
            }
            let parsed = DiscuzParser.parseSearch(html, page: page)
            if append {
                var seen = Set(searchHits.map(\.id))
                searchHits.append(contentsOf: parsed.hits.filter { seen.insert($0.id).inserted })
            } else {
                searchHits = parsed.hits
            }
            searchPage = page
            visitedSearchURLs.insert(target)
            let next = DiscuzParser.searchNextURL(html, baseURL: target, page: page)
            searchNextURL = next.flatMap { visitedSearchURLs.contains($0) ? nil : $0 }
            searchHasNext = searchNextURL != nil
            searchState = .idle
        } catch {
            guard searchGeneration == generation else { return }
            searchState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }
}
