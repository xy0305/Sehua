import Foundation

// Replace only network transport; compile the entire production AppStore unchanged.
@MainActor
final class WebSession {
    static let shared = WebSession()
    let baseURL = URL(string: "https://www.sehuatang.org")!
    var requests: [String] = []
    var handler: (String) async throws -> String = { _ in "" }
    func url(_ path: String) -> URL { URL(string: path, relativeTo: baseURL)!.absoluteURL }
    func fetchHTML(_ path: String) async throws -> String {
        requests.append(path)
        return try await handler(path)
    }
}

@main
struct SearchStateFixtures {
    @MainActor static func main() async {
        let web = WebSession.shared
        let store = AppStore()
        func page(_ tid: Int, next: Int?) -> String {
            var html = "<a href='forum.php?mod=viewthread&tid=\(tid)'>Fixture</a>"
            if let next { html += "<a href='search.php?mod=forum&searchid=0&searchmd5=REDACTED&page=\(next)&mobile=2'>下一页</a>" }
            return html
        }
        web.handler = { _ in page(1, next: 2) }
        await store.search("first")
        precondition(store.searchHits.count == 1 && store.searchHasNext)
        web.handler = { _ in throw URLError(.timedOut) }
        await store.loadMoreSearch()
        precondition(store.searchHits.count == 1 && store.searchPage == 1)
        let failedURL = web.requests.last!
        let count = web.requests.count
        await store.loadMoreSearch()
        precondition(web.requests.count == count, "Failure must not auto retry")
        web.handler = { _ in page(1, next: 3) }
        await store.retrySearch()
        precondition(web.requests.last == failedURL)
        precondition(!failedURL.contains("srchtxt="))
        precondition(store.searchPage == 2 && store.searchHasNext && store.searchHits.count == 1, "Overlap must not end paging")
        web.handler = { _ in page(2, next: nil) }
        await store.loadMoreSearch()
        precondition(store.searchHits.count == 2 && store.searchPage == 3 && !store.searchHasNext)
        await store.search("")
        let clearedCount = web.requests.count
        await store.retrySearch()
        await store.loadMoreSearch()
        precondition(store.searchHits.isEmpty && web.requests.count == clearedCount)

        var delayed: CheckedContinuation<String, Error>?
        web.handler = { _ in try await withCheckedThrowingContinuation { delayed = $0 } }
        let old = Task { await store.search("old") }
        while delayed == nil { await Task.yield() }
        web.handler = { _ in page(9, next: nil) }
        await store.search("new")
        delayed!.resume(returning: page(8, next: 2))
        await old.value
        precondition(store.searchHits.map(\.id) == [9] && !store.searchHasNext, "Stale response must not overwrite new query")

        web.handler = { _ in throw URLError(.timedOut) }
        await store.search("replacement")
        precondition(store.searchHits.map(\.id) == [9], "Failed replacement must preserve loaded results")
        web.handler = { _ in page(10, next: nil) }
        await store.retrySearch()
        precondition(store.searchHits.map(\.id) == [10])
        print("Production AppStore search state fixtures passed: cursor, failed append, explicit retry, overlap, clear, new query generation, retained results.")
    }
}
