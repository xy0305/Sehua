# ResourceLinkExtractor 离线测试夹具

macOS CI（Xcode Command Line Tools，Swift 5，macOS 12+）：

```sh
swiftc -parse-as-library \
  SeHuaTang/Models/Models.swift \
  SeHuaTang/Parser/HTML.swift \
  SeHuaTang/Services/ResourceLinkExtractor.swift \
  Tests/ResourceLinkExtractorFixtures.swift \
  -o /tmp/resource-link-fixtures
/tmp/resource-link-fixtures
```

只编译 Foundation/CoreFoundation/WebKit 和模型、HTML 辅助函数，不导入 SwiftUI、不启动 App、不读取默认 cookie、不请求登录附件。所有测试均注入内存 TXT loader，域名为保留测试域名 `forum.invalid`。

覆盖：完整 magnet 的 dn/tr 与 %26；HTML amp/numeric 实体；URL 的 %7C ed2k 管道；ed2k 空格、扩展字段；v1 hex/base32 与 v2 btmh；无效 hash；稳定去重与来源合并；有效非空压缩包标记组优先（即使组内链接无压缩后缀）；目录树优先排除；失败/空 TXT/登录 HTML 回退与警告；回退中的 dn 压缩后缀；手动不筛选；正文锚点 title 标记 TXT 与相对地址；明确无链接错误；取消不吞。

运输层 4 MiB 硬上限、UTF-8/UTF-16 BOM/GB18030、WK 默认 cookie、Safari UA、Referer 需要另行使用受控服务器的 macOS 集成测试；本夹具不会实际访问站点。当前 Linux/iSH 环境无 Swift 编译器，未执行 macOS 编译测试，不应称为已通过 CI。

API：`extract(detail:base:)` 返回链接数组；推荐 `extractResult(detail:base:mode:loader:)` 返回 resources（链接与来源）、warnings、usedArchiveGroup。数组简便 API 不向调用方呈现成功回退的警告；UI/推送调用层应使用 Result 并展示 warnings。所有 API 为 internal（现有模型非 public）。

手动模式需要调用方传入所选内容构成的 ThreadDetail，或直接用 `links(in:)` 验证所选/粘贴文本；不会因为附件名或压缩后缀过滤有效链接。

限制：与脚本相同，只支持 magnet/ed2k，不解压、不处理种子文件或其他网盘 URL。压缩包标记组优先不混入普通组；无有效标记组时收集全部可用链接，再按文件名后缀优先。来源去重为标准化后的完整字符串，不按 infohash 合并不同 tr/dn 参数。只恢复 ed2k 管道编码，绝不整体 URL 解码 magnet。HTML 实体支持项目原有基础/数字实体及协议结构常见实体，不是完整 HTML5 实体表。正文使用现有模型与 HTML 解析工具，不能恢复此前 parser 丢弃的内容。默认读取依赖 Apple WebKit；非 WebKit 平台需注入 loader。默认传输沿用 URLSession cookie 域匹配及重定向行为，不人为拼接 Cookie 头，不持久化、不打印 cookie；只在实际调用默认 loader 时读取登录态。请求 base 参数应传当前帖子完整 URL。
