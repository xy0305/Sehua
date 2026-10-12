# 后台解压队列接入合同（2026-10-11）

## 2026-10-12 上传脚本协议修正（以下首版范围已被此节替代）

基于核对远端 f158ea3（含70/c1275bc与71详情性能提交），独立工作树修复；不改详情/图像/搜索模块。

- 本App同账户已受理任务按链接各建队列，保留提交前完整首屏快照；批次必须先有完整逐链接POST受理证据，之后逐项精确hash+目标CID+完成度匹配。相同名称/大小的竞争链接不自动归属。
- task.file_id 可为目标CID，绝不再当实体fid；实体源由目标直属目录快照new唯一名称/大小 + 有效SHA1/pick_code识别，复查持久身份。旧包、目录、无hash、未知提交均不获授权。
- 移除源1GiB、输出1GiB/合计2GiB的本地下载限制；这是云端释放而非本地解压。支持独立ed2k zip/7z/rar/tar/gz/bz2/xz；magnet/http、分卷等缺少逐文件来源证据仍不冒险。
- extract_info使用paths=文件、file_name=完整相对目录路径；上传脚本对子目录重复传paths/file_name不直接推广到深层路径，交叉核对公开客户端extract_list。显式file_category=0/1优先，缺字段才采用上传脚本size=0且ico为空识别目录。
- 根层extract_dir[]/extract_file[]重复键提交；不默认脱单层目录。清单每页<999、非空根、无非空next_marker、可选count一致、无重复/穿越名；深度≤5，合计2000预算且每目录扣20，最多100次目录读取。超限/截断不提交，原包保留。
- extract_id释放percent明确100后，重新验证目标路径与完整输出树；新根ID不得在解压前快照，所有叶文件必须名称/大小/SHA1精确匹配，子目录必须清单完整、无多/漏项。缺SHA1可解压但绝不回收。
- 保持解析/释放/回收写前持久化，unknown/submitting重启不重放；仅精确fid[0]+pid调用rb/delete移115回收站，不永久删除、不清垃圾。12次/24小时、每轮4项、5分钟间隔和iOS best effort不变；受理即结束推送，不自动播放。
- 本轮只用上传代码与URLProtocol生产夹具，无真实115写入/删除；仍需隔离样本和明确授权方可真机验收。

以下为原首版历史审阅记录，不作为当前支持范围：

基线已从 origin/main 核对：3ef4e273e722463e17724046a38f115558f1f5f6（69），没有引入其他项目记忆。

## UI接入（已在754e92e完成）

帖子及归档页已将新受理提交接入 `autoExtraction: SHT115ExtractionPolicy.enabled()`，并在受理后调用 `ExtractBackground.kick()`，不等待队列、下载或解压完成，不自动播放。旧的目录压缩包扫描写入及等待播放循环已移除。设置已添加独立开关；账户/CID配置保存先停止旧调度再恢复当前队列。任务列表限定当前账户/父目录，详情展示队列状态、尝试次数及持久取消。

以下保留接入合同以便审阅：

1. 新提交的调用改为：

```swift
let resource = try await service.submit(urls: links, resourceID: resourceID,
    settings: settings, autoExtraction: SHT115ExtractionPolicy.enabled())
ExtractBackground.kick() // 不 await；受理即可结束按钮流程
```

2. 删除 ThreadDetailView / Pan115ResourceView / Pan115TasksView 中“受理后等下载完成、扫描所有 archive 后自动 requestExtraction”的循环，尤其不能再自动处理历史目录的所有压缩包。队列只消费本次提交前记录的 baseline + 本次 accepted task ID。
3. 开关 UserDefaults 键 `avdb.115.backgroundExtraction`，默认 true。独立于“不自动播放/不等待下载”偏好。关闭/切换 Cookie/切换父 CID 都要 `ExtractBackground.stop()`；重新开启或前台刷新执行 `ExtractBackground.kick()`。关闭暂停全局处理；单项取消是持久终态。
4. 任务状态：按资源 `extractionQueue ?? []` 展示 `state.rawValue`、`note`、`attempts`；取消按钮调用 `service.cancelExtractionQueue(resourceID:queueID:settings:)`。仅展示当前 account + parentCID；不要用旧目录 listing 自动创建队列。
5. 刷新读后可 kick，不 await 云端完成。说明 iOS BGProcessing / beginBackgroundTask 都是 best effort，不保证长时间运行、定时运行或强杀后执行；本地队列可在下次打开后读取恢复。

## 真实公开契约审阅

审阅 ChenyangGao/p115client main 的 `p115client/client.py`（HTTPS 正常证书验证；本次没有读取/输出 COOKIE115，也没有真实写入）：

- `extract_push` / `/files/push_extract` 解析与 `extract_progress` / GET `/files/add_extract_file?extract_id=` 是不同阶段，不将解析100%误当释放完成。
- POST `/files/add_extract_file` 支持 pick_code/to_pid/paths/extract_file[]；GET `/files/extract_info` 使用 next_marker 游标，不能仅因少于999项就假定完整。
- 云端会把 `< > "` 替换、截断超长文件名、特殊隐藏名称翻倍、重名改名；故首版拒绝此类名称，要求终止游标为空、无重名。
- POST `/rb/delete` 是文件移至回收站；永久清空另有 recyclebin_clean API。仅调用准确 `fid[0]=sourceID&pid=sourceParent`，不调用 clean、不传目录ID。
- 非官方公开客户端契约仅作交叉检查，并不等于真实账户写入验收。真实 extract_info 未必提供 SHA1，任务列表未必提供 file_id；缺失则保留/等待预算到期，不能据名字大小推定来源或完整性。

## 首版保守支持范围

只对本 App 新受理且 opt-in 的单链接 ed2k zip/7z/rar，源≤1GiB；提交前目标目录须在既有路径首屏中完整返回（≤100项、总数明确），否则不登记自动任务；不新增前台分页等待。后台只读目标直属目录，最多2000项、不递归扫描。fresh任务必须同父目标目录 status=2、percent=100、唯一匹配且提供 file_id；ID必须不在提交前baseline中；fresh源ID/目录/名称/大小/pickcode/SHA1全相符。输出仅平铺非空文件（单项≤1GiB，总计≤2GiB，<999项），清单游标明确终止。历史 accepted/unknown 不迁移；magnet、多链接、子目录、加密、超限不冒险。

自动回收还要求本次队列授权ID、accepted extractID、释放100%、fresh目标路径、fresh新输出唯一ID且不在解压前baseline、每个输出清单SHA1与fresh文件SHA1+大小匹配，以及fresh准确源ID/pickcode/SHA1/大小/账户/目录再次相符。只要完整性字段缺失，即使解压受理也永久停在保留状态，不自动删。

每轮最多4条到期任务；每项最多12次、24小时、间隔至少5分钟；无sleep轮询。取消持久化；重启只恢复记录和读校验，submitting→unknown，unknown写入不重放。

## 已联网核对的参考（收尾2026-10-11）

- https://github.com/ChenyangGao/p115client/blob/main/p115client/client.py ：复用现成115公开客户端所描述的 `extract_push`（解析）、`extract_info`（清单）、POST/GET `add_extract_file`（释放及进度）和 `/rb/delete`（移回收站）契约；未引入通用框架，未使用永久清空API。此为非官方客户端源码，不应称为115官方保证。
- https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask ：系统可中断后台处理，应安装expirationHandler；设备活动亦可导致终止。
- https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate ：最早时间不是保证执行时间；5分钟是本地重试下限，不是后台定时承诺。

本轮仅HTTPS公开源码/文档读取、受控URLProtocol回归和GitHub CI，不执行真实115写入、删除或用户既有资源清理。没有真机后台时机、真实云解压或回收验收；真实接口缺少file_id或SHA1时，应以保留原包为正确行为。

## mock/CI

新增 QueueFixtures（完整流程、缺fileID、历史源、缺输出hash、取消、账户/父目录隔离、旧记录不入队、提交未知、删除超时不重放）；扩展 CleanupFixtures（无授权、取消、目录输出、缺hash、源hash改变）；适配旧 Extraction/Sequence 显式授权。

CI工作流新增队列步骤，完整旧69搜索/67诊断回归保持。原工作流 workflow_dispatch token 返回403，因此通过既有 `recovery/115-evidence-*` push过滤触发，不改变主线/不发布。

真实写验收需要用户另行授权：隔离新建可控测试目录 + 上传自制≤几十KiB、1个平铺TXT的小ZIP + 仅测试文件的解析/解压 + 仅该源包移回收站；故障注入用mock，禁动既有诊断/文件，禁永久删除。真实API不能提供完整SHA1清单时，应验收“成功解压但源保留”，不能宣称自动清理可用。
