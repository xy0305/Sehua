# 后台解压队列接入合同（2026-10-11）

基线已从 origin/main 核对：3ef4e273e722463e17724046a38f115558f1f5f6（69），没有引入其他项目记忆。

## 父分支接入（尚未修改这些 UI 文件，避免与并行 UI 工作冲突）

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

## mock/CI

新增 QueueFixtures（完整流程、缺fileID、历史源、缺输出hash、取消、账户/父目录隔离、旧记录不入队、提交未知、删除超时不重放）；扩展 CleanupFixtures（无授权、取消、目录输出、缺hash、源hash改变）；适配旧 Extraction/Sequence 显式授权。

CI工作流新增队列步骤，完整旧69搜索/67诊断回归保持。原工作流 workflow_dispatch token 返回403，因此通过既有 `recovery/115-evidence-*` push过滤触发，不改变主线/不发布。

真实写验收需要用户另行授权：隔离新建可控测试目录 + 上传自制≤几十KiB、1个平铺TXT的小ZIP + 仅测试文件的解析/解压 + 仅该源包移回收站；故障注入用mock，禁动既有诊断/文件，禁永久删除。真实API不能提供完整SHA1清单时，应验收“成功解压但源保留”，不能宣称自动清理可用。
