# 色花堂 / 98堂 iOS

自用侧载、原生 SwiftUI。页面用 WKWebView 过 Cloudflare / 年龄门 / 登录验证码，解析 Discuz 手机版 HTML 后用原生列表展示，广告节点直接丢掉。

## 打开 / 编译

用 Xcode 16+ 打开 `SeHuaTang.xcodeproj`，选你自己的 Team 签名，Bundle ID 可改，装到手机即可。

部署目标 iOS 17。ATS 已放开（图床 / 线路经常不是标准证书）。

GitHub Actions（`macos-15`）在每次 push `main` 后打一份**未签名 IPA**：

1. 打开 [Actions](https://github.com/xy0305/Sehua/actions)
2. 等 **Build IPA** 跑完
3. 下载 artifact `SeHuaTang-unsigned-ipa`
4. 用自己的证书侧载（AltStore / TrollStore / 爱思 / 巨魔）

也可在 Actions 里手动 **Run workflow**。


## 使用

1. 第一次打开会自动点年龄门。
2. **我的 → 登录**：验证码、Cloudflare 你自己在网页里过，过完返回即写入 Cookie。
3. 线路在「我的」里改（域名轮换时只改这一处）。
4. 帖子详情里的 `magnet:` 可复制或唤起系统/第三方下载器。

## 去广告

解析时丢弃：

- `.show-text` / `.items` / `.items-box` / `#links` / `.js-appJump`
- 标题含赌场、棋牌、百家乐、葡京、招代理、鲍鱼盒子等
- 板块「鲍鱼直播盒子 / 鲍鱼视频」（fid 148、149）

## 源码对应

- 板块：`forum.php?forumlist=1&mobile=2`（已按你给的源码写死分类，启动仍会再拉一次做刷新）
- 列表：`forum.php?mod=forumdisplay&fid=&mobile=2`（`.n5_htmk` / `.ztyzjj` / `img.lazy.imagelist`）
- 详情：`forum.php?mod=viewthread&tid=&mobile=2`（磁力、附件、图片）
- 登录：`member.php?mod=logging&action=login&mobile=2`

详情页若解析不准，把该页「查看网页源代码」发我即可改 Parser。
