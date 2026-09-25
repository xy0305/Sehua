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

    func loadForums() async {
        forumState = .loading
        do {
            let html = try await WebSession.shared.fetchHTML("forum.php?forumlist=1&mobile=2")
            if DiscuzParser.looksLikeChallenge(html) {
                forumState = .failed("需要过验证，请到「我的」打开网页登录")
                return
            }
            let cats = DiscuzParser.parseForumList(html)
            categories = cats
            forumState = .idle
        } catch {
            forumState = .failed(error.localizedDescription)
        }
    }

    func loadThreads(fid: Int, page: Int = 1, typeid: Int = 0, order: String = "dateline", append: Bool = false) async {
        if !append {
            threadState = .loading
            if page == 1 { threads = [] }
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
            if DiscuzParser.looksLikeChallenge(html) {
                threadState = .failed("需要过验证")
                return
            }
            let parsed = DiscuzParser.parseThreadList(html, fid: fid, page: page)
            if append {
                let exist = Set(threads.map(\.id))
                threads.append(contentsOf: parsed.threads.filter { !exist.contains($0.id) })
            } else {
                threads = parsed.threads
            }
            threadTypes = parsed.types
            threadPage = page
            threadHasNext = parsed.hasNext
            if !parsed.boardName.isEmpty { boardTitle = parsed.boardName }
            threadState = .idle
        } catch {
            threadState = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard let fid = currentFID, threadHasNext, threadState != .loading else { return }
        await loadThreads(fid: fid, page: threadPage + 1, typeid: currentTypeID, order: currentOrder, append: true)
    }

    func loadPortal() async {
        portalState = .loading
        do {
            let html = try await WebSession.shared.fetchHTML("portal.php?mod=index&mobile=2")
            if DiscuzParser.looksLikeChallenge(html) {
                portalState = .failed("需要过验证，请到「我的」打开网页登录")
                return
            }
            portal = DiscuzParser.parsePortal(html, base: WebSession.shared.baseURL)
            portalState = .idle
        } catch {
            portalState = .failed(error.localizedDescription)
        }
    }

    func search(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchState = .loading
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let path = "search.php?mod=forum&searchsubmit=yes&srchtxt=\(encoded)&mobile=2"
        do {
            let html = try await WebSession.shared.fetchHTML(path)
            searchHits = DiscuzParser.parseSearch(html)
            searchState = .idle
        } catch {
            searchState = .failed(error.localizedDescription)
        }
    }
}
