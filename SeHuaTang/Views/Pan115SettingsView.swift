import SwiftUI

struct Pan115SettingsView: View {
    @State private var cookie = ""
    @AppStorage("avdb.115.backgroundExtraction") private var backgroundExtraction = true
    @State private var parentCID = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("AVDB115 兼容配置") {
                SecureField("115 Cookie（UID / CID / SEID）", text: $cookie)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                TextField("归档父目录 CID", text: $parentCID)
                    .keyboardType(.numberPad)
                Button("保存到本机") { save() }
                    .disabled(busy)
                Text("使用 AVDB 相同配置键。Cookie 不显示、不写入任务记录；本机配置与登录网页会话独立。请勿将 Cookie 分享给他人。")
                    .font(.footnote)
            }
            Section("只读检查") {
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("验证签名与父目录（不创建任务）")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy)
                if let message { Text(message).font(.footnote) }
                Text("检查仅读取签名和目录，不提交测试磁力、不上传、不创建目录。")
                    .font(.footnote)
            }
            Section("安全后台解压") {
                Toggle("自动解压新受理压缩包", isOn: $backgroundExtraction)
                    .onChange(of: backgroundExtraction) { enabled in
                        ExtractBackground.stop()
                        if enabled { ExtractBackground.kick() }
                    }
                Text("默认开启，仅处理本App同账户新受理且逐项来源确证的 ed2k 压缩包；批量链接逐项核验，子目录须完整读取清单。推送不等待下载、不自动播放；完整输出身份、大小与哈希核验后，仅该原包移115回收站。证据缺失、失败或未知均保留，不重发未知写入。关闭暂停全局队列，单项取消保存在本机。")
                    .font(.footnote)
                Text("iOS后台为尽力执行：系统决定运行时机与时长，不保证持续运行、定时运行或强杀后执行。重新打开后恢复持久队列；每项最多12次/24小时。")
                    .font(.footnote)
            }
            Section("使用说明") {
                Text("从帖子详情进入「115 归档 / 播放」，核对提取链接与来源后确认推送。每个帖子使用 tid 独立目录；手动链接保留所有输入，不按格式筛选。")
                Text("压缩包仅由已授权安全队列处理；加密、分卷、同名歧义或无法提供完整证据时保留原包，请到115核对。")
                Text("任务记录保存在本机。后台不保证执行，请重新打开后查看或手动刷新。播放仅由用户选择视频触发；原画编码和子请求认证可能受系统限制。")
            }
        }
        .navigationTitle("115 设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            let settings = SHT115Settings.load()
            cookie = settings.cookie
            parentCID = settings.parentCID
        }
    }

    private func save() {
        do {
            let settings = SHT115Settings(cookie: cookie, parentCID: parentCID)
            try settings.validate()
            ExtractBackground.stop()
            UserDefaults.standard.set(settings.cookie, forKey: "avdb.115.cookie")
            UserDefaults.standard.set(settings.parentCID, forKey: "avdb.115.folderCID")
            message = "已保存配置。"
            ExtractBackground.kick()
        } catch {
            message = "配置格式无效，请检查 Cookie 的 UID / CID / SEID 与父目录 CID。"
        }
    }

    @MainActor private func check() async {
        busy = true
        defer { busy = false }
        do {
            let settings = SHT115Settings(cookie: cookie, parentCID: parentCID)
            try settings.validate()
            let service = try Pan115UIService.get()
            try await service.validateSettings(settings)
            message = "只读检查通过：签名与父目录可访问。尚未保存的修改请点保存。"
        } catch {
            message = "只读检查失败。请检查 Cookie 是否过期、目录 CID 是否存在及网络连接。"
        }
    }
}
