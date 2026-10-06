import Foundation

@main struct ForumDirectoryFixtures {
    static func main() {
        let builtin = BuiltinForums.categories
        precondition(builtin.first?.name == "原创BT电影")
        precondition(builtin.first?.id == "bt")
        precondition(builtin.map(\.id) == ["bt", "online", "archive", "pic", "novel", "talk"])

        // The live parser uses the same document order. 原创BT电影 is first only
        // because the site lists it first; its id is an ordinary tab id.
        let liveHTML = #"""
        <li id="a_tab1"><a href="forum.php?gid=1">原创BT电影</a></li>
        <li id="a_tab2"><a href="forum.php?gid=2">在线视频区</a></li>
        <div id="tab1_content"><a href="forum.php?mod=forumdisplay&amp;fid=36" class="btdb">亚洲无码原创<span class="num">3</span></a></div>
        <div id="tab2_content"><a href="forum.php?mod=forumdisplay&amp;fid=41" class="btdb">国产自拍<span class="num">1</span></a></div>
        """#
        let live = DiscuzParser.parseForumList(liveHTML)
        precondition(live.map(\.name) == ["原创BT电影", "在线视频区"])
        precondition(live.map(\.id) == ["1", "2"])
        precondition(!live.contains { $0.id == "bt" || $0.name == "原创 BT 电影" })

        let fresh = ForumDirectoryState.initialExpandedIDs()
        precondition(fresh.isEmpty)
        precondition(!fresh.contains("bt") && !fresh.contains("1") && !fresh.contains(live[0].id))

        let remembered = ForumDirectoryState.restoredExpandedIDs(stored: "online\nbt\n")
        precondition(remembered == ["online", "bt"])
        precondition(ForumDirectoryState.restoredExpandedIDs(stored: nil).isEmpty)
        precondition(ForumDirectoryState.restoredExpandedIDs(stored: "\n  \n").isEmpty)
        precondition(ForumDirectoryState.persistedValue(for: remembered) == "bt\nonline")

        // Refresh replaces category values and may drop an id, but must not force
        // the first group open or discard a still-valid user choice.
        let refreshed = ForumDirectoryState.reconciledExpandedIDs(["bt", "removed"], categories: builtin)
        precondition(refreshed == ["bt"])
        let afterReturn = ForumDirectoryState.reconciledExpandedIDs(refreshed, categories: builtin)
        precondition(afterReturn == refreshed)

        let opened = ForumDirectoryState.toggled([], categoryID: "online")
        precondition(opened == ["online"])
        precondition(!opened.contains("bt"))
        let closed = ForumDirectoryState.toggled(["bt", "online"], categoryID: "bt")
        precondition(closed == ["online"])
        let reopened = ForumDirectoryState.toggled(closed, categoryID: "bt")
        precondition(reopened == ["bt", "online"])

        let liveKept = ForumDirectoryState.reconciledExpandedIDs(["2"], categories: live)
        precondition(liveKept == ["2"])
        precondition(!liveKept.contains(live[0].id))
        let dropped = ForumDirectoryState.reconciledExpandedIDs(["9"], categories: live)
        precondition(dropped.isEmpty)

        print("Forum directory expansion policy fixtures passed")
    }
}
