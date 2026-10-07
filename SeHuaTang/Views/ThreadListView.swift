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
        HStack(spacing: 10) {
            Label("\(store.threadTypes.first(where: { $0.id == typeID })?.name ?? "全部")", systemImage: "line.3.horizontal.decrease")
            Text("·")
            Text(orders.first(where: { $0.0 == order })?.1 ?? "最新")
            Text("·")
            Text("第\(store.threadSelectedPage)页")
            Spacer(minLength: 0)
            Button { optionsPresented = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(ForumChrome.accent.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("筛选、排序与页码选项")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(ForumChrome.secondary)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(ForumChrome.page)
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
    @State private var appeared = false
    @State private var intersectsViewport = false
    @GestureState private var draggingPreview = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rotates: Bool {
        PresentationTiming.canRotate(count: item.previewURLs.count, visible: appeared && intersectsViewport,
            foreground: scenePhase == .active, reducedMotion: reduceMotion,
            interacting: draggingPreview, viewingImage: false)
    }
    private var rotationKey: String { "\(rotates)-\(previewPage)-\(item.previewURLs.count)" }

    private var destination: some View {
        ThreadDetailView(tid: item.id, title: item.title, sourceFID: item.fid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !item.previewURLs.isEmpty {
                GeometryReader { geometry in
                    let height = min(280, max(220, geometry.size.width * 0.72))
                    ZStack(alignment: .bottom) {
                        TabView(selection: $previewPage) {
                            ForEach(Array(item.previewURLs.enumerated()), id: \.offset) { index, url in
                                SiteImage(url: url, contentMode: .fit, preservesIntrinsicAspectRatio: false, animationBudget: 4 * 1024 * 1024) {
                                    ZStack { ForumChrome.page; ProgressView() }
                                }
                                .frame(width: geometry.size.width, height: height)
                                .background(ForumChrome.page)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                            .frame(height: 72)
                            .allowsHitTesting(false)
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 5)
                        .updating($draggingPreview) { _, state, _ in state = true })
                    .onGeometryChange(for: Bool.self) { proxy in
                        let rect = proxy.frame(in: .global)
                        let viewport = UIScreen.main.bounds
                        return rect.intersects(viewport) && rect.width > 0 && rect.height > 0
                    } action: { intersectsViewport = $0 }
                    .onAppear { appeared = true }
                    .onDisappear { appeared = false; intersectsViewport = false }
                    .task(id: rotationKey) {
                        guard rotates else { return }
                        do {
                            try await Task.sleep(nanoseconds: UInt64(PresentationTiming.carouselInterval * 1_000_000_000))
                            try Task.checkCancellation()
                            guard rotates else { return }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                previewPage = (previewPage + 1) % item.previewURLs.count
                            }
                        } catch { /* Leaving the viewport or manual input cancels the tick. */ }
                    }
                    .frame(height: height)
                    .overlay(alignment: .topLeading) {
                        if item.isSticky {
                            Text("置顶")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(.white)
                                .background(ForumChrome.accent, in: Capsule())
                                .padding(10)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 5) {
                            ForEach(item.previewURLs.indices, id: \.self) { index in
                                Capsule().fill(index == previewPage ? Color.white : Color.white.opacity(0.45))
                                    .frame(width: index == previewPage ? 14 : 5, height: 5)
                            }
                        }
                        .padding(12)
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(previewPage + 1)/\(item.previewURLs.count)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(.white).background(.black.opacity(0.35), in: Capsule())
                            .padding(10).allowsHitTesting(false)
                    }
                }
                .aspectRatio(1 / 0.72, contentMode: .fit)
                .frame(minHeight: 220, maxHeight: 280)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
            }
            NavigationLink { destination } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ForumChrome.text)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(item.excerpt)
                            .font(.system(size: 14))
                            .foregroundStyle(ForumChrome.secondary)
                            .lineLimit(2)
                            .lineSpacing(2)
                    }
                    HStack(spacing: 8) {
                        Text(String((item.author.isEmpty ? "匿名" : item.author).prefix(1)))
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(ForumChrome.accent, in: Circle())
                        Text(item.author.isEmpty ? "匿名" : item.author)
                            .lineLimit(1)
                        if !item.dateText.isEmpty { Text(item.dateText).lineLimit(1) }
                        Spacer(minLength: 0)
                        if !item.replies.isEmpty { Label(item.replies, systemImage: "bubble") }
                        if !item.views.isEmpty { Label(item.views, systemImage: "eye") }
                    }
                    .font(.caption)
                    .foregroundStyle(ForumChrome.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ForumPressStyle())
        }
        .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).stroke(ForumChrome.line.opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
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
