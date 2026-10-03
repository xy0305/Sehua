import SwiftUI

struct Pan115SettingsView: View {
    @State private var cookie = ""
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
            Section("使用说明") {
                Text("从帖子详情进入「115 归档 / 播放」，核对提取链接与来源后确认推送。每个帖子使用 tid 独立目录；手动链接保留所有输入，不按格式筛选。")
                Text("离线完成不代表压缩包可以播放。压缩包需明确确认解压（若服务支持），自动云解压；仅释放明确完成且新输出验证后将本任务原包移入回收站。")
                Text("任务记录保存在本机。iOS 关闭应用后不持续轮询；回来请手动刷新。原生播放器优先 HLS 转码，原画编码和子请求认证可能受系统限制。")
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
            UserDefaults.standard.set(settings.cookie, forKey: "avdb.115.cookie")
            UserDefaults.standard.set(settings.parentCID, forKey: "avdb.115.folderCID")
            message = "已保存配置。"
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
