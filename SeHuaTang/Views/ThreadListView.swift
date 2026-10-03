import SwiftUI

struct ThreadListView: View {
    let board: ForumBoard
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var session: WebSession
    @State private var typeID = 0
    @State private var order = "dateline"
    @State private var visibleThreadID: Int?
    @State private var pageInput = ""
    @State private var optionsPresented = false
    @FocusState private var pageInputFocused: Bool

    private let orders: [(String, String)] = [
        ("dateline", "最新"),
        ("heats", "热门"),
        ("replies", "回复"),
        ("views", "查看")
    ]

    var body: some View {
        VStack(spacing: 0) {
            compactToolbar
            ChallengeBanner()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = store.threadState.errorMessage, store.threads.isEmpty {
                        ContentUnavailableView {
                            Label("加载失败", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") { Task { await reload() } }
                        }
                        .padding(.vertical, 32)
                    } else if store.threads.isEmpty && store.threadState == .idle {
                        ContentUnavailableView("暂无帖子", systemImage: "text.bubble", description: Text("试试其他分类或下拉刷新"))
                            .padding(.vertical, 32)
                    }
                    ForEach(store.threads) { item in
                        ThreadCard(item: item)
                        .id(item.id)
                        .buttonStyle(ForumPressStyle())
                        .onAppear {
                            if item.id == store.threads.last?.id {
                                Task { await store.loadMore() }
                            }
                        }
                    }
                    if store.threadHasNext && store.threadState == .idle {
                        Color.clear.frame(height: 1)
                            .id("continuation-\(store.threadPage)")
                            .onAppear { Task { await store.loadMore() } }
                    }
                    Group {
                    if store.threadState == .loading {
                        ProgressView().padding()
                    } else if let error = store.threadState.errorMessage, !store.threads.isEmpty {
                        VStack(spacing: 8) {
                            Text(error).font(.footnote).foregroundStyle(ForumChrome.secondary)
                            Button("重试") { Task { await store.retryThreadRequest() } }
                        }
                        .padding(16)
                    } else if !store.threads.isEmpty {
                        Text(store.threadHasNext ? "上滑累计加载下一页" : "已到最后一页")
                            .font(.caption)
                            .foregroundStyle(ForumChrome.secondary)
                            .padding(16)
                    }
                    }
                    .frame(minHeight: 64)
                }
                .scrollTargetLayout()
                // Appending and asynchronous preview completion are not user
                // navigation. Do not animate layout or write a new scroll ID.
                .transaction { $0.animation = nil }
            }
            .scrollPosition(id: $visibleThreadID, anchor: .top)
            .background(ForumChrome.page)
            .refreshable { await reload() }
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.blue)
        .navigationBarTitleDisplayMode(.inline)
        .forumNavigation(title: board.name, refresh: { Task { await reload() } })
        .sheet(isPresented: $optionsPresented) {
            NavigationStack {
                Form {
                    Section("分类") { typeBar }
                    Section("排序") { orderBar }
                    Section("页码") { pageBar }
                    Section("版块") {
                        Text(board.meta.isEmpty ? "版块主题 · 浏览与交流" : board.meta)
                            .font(.footnote).foregroundStyle(.secondary)
                        NavigationLink("发帖 · 网页表单") {
                            LoginWebView(url: session.url("forum.php?mod=post&action=newthread&fid=\(board.id)&mobile=2"), title: "发帖 · 网页表单")
                        }
                    }
                    Button("重置为全部 · 最新 · 第1页") {
                        typeID = 0
                        order = "dateline"
                        pageInputFocused = false
                        optionsPresented = false
                        Task { await reload() }
                    }
                }
                .navigationTitle("列表选项")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { pageInputFocused = false; optionsPresented = false }
                } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: store.threadReplacementRevision) { _, _ in
            visibleThreadID = store.threads.first?.id
            pageInput = ""
        }
        .task {
            // A popped detail must not clear the list or fetch page one again.
            if store.currentFID == board.id,
               store.currentTypeID == typeID, store.currentOrder == order,
               !store.threads.isEmpty { return }
            await reload()
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 8) {
            Text("\(store.threadTypes.first(where: { $0.id == typeID })?.name ?? "全部") · \(orders.first(where: { $0.0 == order })?.1 ?? "最新") · 第\(store.threadSelectedPage)页" + (store.threadPage > store.threadSelectedPage ? "–\(store.threadPage)页" : ""))
                .font(.caption).foregroundStyle(ForumChrome.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button { optionsPresented = true } label: {
                Label("选项", systemImage: "slider.horizontal.3").font(.subheadline)
            }
            .accessibilityLabel("筛选、排序与页码选项")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(ForumChrome.bar)
    }

    private var typeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(store.threadTypes) { t in
                    Button {
                        typeID = t.id
                        optionsPresented = false
                        Task { await reload() }
                    } label: {
                        Text(t.name)
                            .font(.system(size: 15, weight: typeID == t.id ? .semibold : .regular))
                            .foregroundStyle(typeID == t.id ? ForumChrome.blue : ForumChrome.text)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .overlay(alignment: .bottom) {
                                if typeID == t.id {
                                    Capsule().fill(ForumChrome.blue).frame(width: 22, height: 3)
                                        .padding(.bottom, 4)
                                }
                            }
                    }
                    .buttonStyle(ForumPressStyle())
                }
            }
            .padding(.horizontal, 6)
        }
        .background(ForumChrome.bar)
    }

    private var orderBar: some View {
        HStack(spacing: 16) {
            ForEach(orders, id: \.0) { item in
                Button {
                    order = item.0
                    optionsPresented = false
                    Task { await reload() }
                } label: {
                    Text(item.1)
                        .font(.system(size: 13, weight: order == item.0 ? .semibold : .regular))
                        .foregroundStyle(order == item.0 ? ForumChrome.blue : ForumChrome.secondary)
                }
                .buttonStyle(ForumPressStyle())
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(ForumChrome.bar)
        .overlay(alignment: .bottom) { ForumChrome.line.frame(height: 0.5) }
    }

    private var pageBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Button("上一页") { optionsPresented = false; Task { await store.selectThreadPage(store.threadSelectedPage - 1) } }
                    .disabled(store.threadSelectedPage <= 1 || store.threadState == .loading)
                Text("第 \(store.threadSelectedPage) 页" + (store.threadTotalPages.map { " / \($0)" } ?? ""))
                    .monospacedDigit()
                Button("下一页") { optionsPresented = false; Task { await store.selectThreadPage(store.threadSelectedPage + 1) } }
                    .disabled(store.threadState == .loading || (store.threadTotalPages.map { store.threadSelectedPage >= $0 } ?? (!store.threadHasNext && store.threadPage == store.threadSelectedPage)))
                Spacer(minLength: 0)
                TextField("页码", text: $pageInput)
                    .keyboardType(.numberPad)
                    .focused($pageInputFocused)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .accessibilityLabel("输入要跳转的页码")
                Button("跳转") {
                    guard !pageInput.isEmpty, pageInput.allSatisfy({ $0.isASCII && $0.isNumber }), let page = Int(pageInput) else {
                        store.threadPageError = "请输入有效的整数页码"
                        return
                    }
                    pageInputFocused = false
                    optionsPresented = false
                    Task { await store.selectThreadPage(page) }
                }
                .disabled(store.threadState == .loading)
            }
            if store.threadPage > store.threadSelectedPage {
                Text("已累计加载第 \(store.threadSelectedPage)–\(store.threadPage) 页；选页将替换列表")
                    .foregroundStyle(ForumChrome.secondary)
            } else {
                Text("选页替换列表 · 上滑累计加载")
                    .foregroundStyle(ForumChrome.secondary)
            }
            if let error = store.threadPageError { Text(error).foregroundStyle(.red) }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ForumChrome.bar)
    }

    private func reload() async {
        await store.loadThreads(fid: board.id, typeid: typeID, order: order)
    }
}

struct ThreadCard: View {
    let item: ThreadItem
    @State private var previewPage = 0
    @State private var viewingImage = false

    private var destination: some View {
        ThreadDetailView(tid: item.id, title: item.title, sourceFID: item.fid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink { destination } label: {
            VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(item.author.isEmpty ? "匿名" : item.author)
                if !item.dateText.isEmpty { Text("·"); Text(item.dateText) }
                Spacer(minLength: 0)
                if item.isSticky {
                    Text("置顶").foregroundStyle(ForumChrome.blue)
                }
            }
            .font(.caption)
            .foregroundStyle(ForumChrome.secondary)
            Text(item.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ForumChrome.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !item.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.excerpt)
                    .font(.system(size: 14))
                    .foregroundStyle(ForumChrome.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            }
            .buttonStyle(ForumPressStyle())
            if !item.previewURLs.isEmpty {
                GeometryReader { geometry in
                    let height = min(280, max(220, geometry.size.width * 0.72))
                    TabView(selection: $previewPage) {
                        ForEach(Array(item.previewURLs.enumerated()), id: \.offset) { index, url in
                            Button { viewingImage = true } label: {
                                SiteImage(url: url, contentMode: .fit, preservesIntrinsicAspectRatio: false, animationBudget: 4 * 1024 * 1024) {
                                    ZStack { ForumChrome.page; ProgressView() }
                                }
                                .frame(width: geometry.size.width, height: height)
                                .background(ForumChrome.page)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看第 \(index + 1) 张大图，可缩放")
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(previewPage + 1)/\(item.previewURLs.count) · 点击放大")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .foregroundStyle(.white).background(.black.opacity(0.65), in: Capsule())
                            .padding(8).allowsHitTesting(false)
                    }
                }
                // Height depends only on available card width, never decoded pixels.
                .aspectRatio(1 / 0.72, contentMode: .fit)
                .frame(minHeight: 220, maxHeight: 280)
                .fullScreenCover(isPresented: $viewingImage) {
                    ThreadPreviewViewer(url: item.previewURLs[min(previewPage, item.previewURLs.count - 1)])
                }
            }
            NavigationLink { destination } label: {
            HStack(spacing: 16) {
                Label(item.replies.isEmpty ? "0" : item.replies, systemImage: "bubble")
                if !item.likes.isEmpty { Label(item.likes, systemImage: "hand.thumbsup") }
                if !item.views.isEmpty { Label(item.views, systemImage: "eye") }
            }
            .font(.caption)
            .foregroundStyle(ForumChrome.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            }
            .buttonStyle(ForumPressStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).stroke(ForumChrome.line.opacity(0.5), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// Native full-screen preview. The image loader keeps the site's cookies,
/// referer, bounded GIF decoder and cancellation behavior unchanged.
private struct ThreadPreviewViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ZoomableThreadPreview(url: url).ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.65), in: Circle())
            }
            .padding(16)
            .accessibilityLabel("关闭大图")
        }
    }
}

private struct ZoomableThreadPreview: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .black
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 12
        scroll.bouncesZoom = true
        scroll.delegate = context.coordinator
        let host = UIHostingController(rootView:
            SiteImage(url: url, contentMode: .fit, preservesIntrinsicAspectRatio: false) {
                ProgressView().tint(.white)
            })
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            host.view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.host = host
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var host: UIViewController?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host?.view }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, let image = host?.view else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: image)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                      width: size.width, height: size.height), animated: true)
            }
        }
    }
}
