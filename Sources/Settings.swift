import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class SettingsSelection {
    var id: String? = "tutorial"
}

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate {
    let selection = SettingsSelection()
    let state: AppState
    init(state: AppState) {
        self.state = state
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Super Input 设置"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = CGSize(width: 740, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsRoot(state: state, selection: selection))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SuperInputSettings")
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ id: String?) {
        selection.id = ["tutorial", "feishu", "general", "diagnostics"].contains(id ?? "") ? id : "tutorial"
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
}

struct SettingsRoot: View {
    @Bindable var state: AppState
    @Bindable var selection: SettingsSelection
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selection.id) {
                Label("配置教程", systemImage: "book.closed").tag("tutorial")
                Label("飞书", systemImage: "paperplane").tag("feishu")
                Label("使用与文件", systemImage: "slider.horizontal.3").tag("general")
                Label("诊断与关于", systemImage: "info.circle").tag("diagnostics")
            }
            .listStyle(.sidebar)
            .navigationTitle("设置")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            switch selection.id {
            case "feishu": FeishuSettings(state: state)
            case "general": GeneralSettings(state: state)
            case "diagnostics": DiagnosticsSettings(state: state)
            default: TutorialSettings(openFeishu: { selection.id = "feishu" })
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem {
                Button { selection.id = "tutorial" } label: { Label("配置教程", systemImage: "book") }
            }
            ToolbarItem {
                Button { state.ruleStore.reload(); state.onRulesChanged?() } label: { Label("重新加载配置", systemImage: "arrow.clockwise") }
            }
        }
    }
}

struct TutorialSettings: View {
    var openFeishu: () -> Void
    @State private var copied = false
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("把文件拖给飞书", systemImage: "paperplane.fill").font(.title2.bold())
                    Text("安装飞书 CLI，连接你自己的账号，再选择允许直接发送的会话。配置一次，以后拖放即可发送。").fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("打开飞书设置", action: openFeishu).buttonStyle(.borderedProminent)
                        Button(copied ? "已复制 Agent 指南" : "复制给 Agent") { copy(SetupGuide.agent); copied = true }
                    }
                    Text("飞书通道通过 CLI 发送文件，无需辅助功能、屏幕录制权限，也无需定位飞书客户端输入框。").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            Section("1 · 安装官方飞书 CLI") {
                Text("先安装 Node.js 与 npm。CLI 要求 Node.js 16 或更新版本，建议使用当前 LTS。已有 lark-cli 可以直接复用。").fixedSize(horizontal: false, vertical: true)
                command(SetupGuide.install)
                command(SetupGuide.inspect)
                Link("查看官方安装说明", destination: SetupGuide.cliURL)
                Text("当前发布版已验证 lark-cli 1.0.98；升级后的命令参数以官方 --help 为准。").font(.caption).foregroundStyle(.secondary)
            }
            Section("2 · 配置你自己的飞书应用") {
                Text("已有可用 CLI 配置可以跳过。首次使用时，在终端运行下面的命令，并按浏览器提示创建和配置应用。应用权限与用户授权都需要开启。").fixedSize(horizontal: false, vertical: true)
                command(SetupGuide.initialize)
                Text("不要覆盖已有应用。由 Agent 操作时，可复制顶部指南，按后台配置和分步授权流程完成。").font(.caption).foregroundStyle(.secondary)
            }
            Section("3 · 登录本人账号并授权") {
                Text("在终端运行，打开返回的链接完成授权。这里申请 IM 与通讯录业务权限，用于会话、联系人查询及本人文件发送。").fixedSize(horizontal: false, vertical: true)
                command(SetupGuide.login)
                command(SetupGuide.verify)
                Text("确认用户身份已验证，并包含 im:message.send_as_user。遇到缺少权限时，根据 CLI 返回的 missing_scopes 和开发者后台链接补齐，再重新授权。").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("4 · 把 CLI 连接到 Super Input") {
                Text("将 command -v lark-cli 返回的完整路径填到 设置 → 飞书 → CLI 路径，点“保存路径”，再点“读取会话 / 检查连接”。也可以在飞书设置中完成登录或补齐权限。").fixedSize(horizontal: false, vertical: true)
                command(SetupGuide.conversations)
                Text("上面的只读命令可帮助确认会话权限。然后亲自勾选允许直接发送的联系人或群聊，并调整显示顺序。未勾选的会话不会出现在拖放卡片里。").fixedSize(horizontal: false, vertical: true)
                Button("前往飞书设置", action: openFeishu)
            }
            Section("5 · 开始拖放") {
                Text("① 把文件拖到菜单栏飞书图标下方。\n② 移到接收框上半区，展开两列授权会话。\n③ 松手到目标卡片，直接发送。\n\n单个文件最多 30 MiB，支持截图和多文件。暂存区里的缩略图也可以重新拖到会话卡片发送。先选你自己的会话做首次验证。").fixedSize(horizontal: false, vertical: true)
            }
            Section("常见问题") {
                Text("终端可用，App 找不到 Node：核对完整 CLI 路径；推荐 Node 与 lark-cli 位于同一个 bin 目录。桌面 App 不继承终端 PATH。\n\n只有机器人身份：重新登录用户身份，Super Input 使用 --as user。\n\n账号发生变化：移除旧账号的授权会话，再读取和勾选。\n\n发送结果不明：先到飞书检查，App 不会自动重发。\n\n文件夹、软件包、符号链接：请展开或压缩后发送。").fixedSize(horizontal: false, vertical: true)
                Text("密钥和登录令牌由 CLI 管理。不要把认证文件、feishu.json 中的账号和会话标识上传到 GitHub。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
    }
    func command(_ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { copy(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("复制命令")
        }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

struct GeneralSettings: View {
    @Bindable var state: AppState
    var body: some View {
        Form {
            Section("飞书文件发送") {
                Text("拖到菜单栏下方 → 上半区展开会话 → 松手到卡片发送。列表只显示你勾选的会话，发送身份绑定当前用户和应用。").fixedSize(horizontal: false, vertical: true)
                LabeledContent("打开暂存区", value: "Control + Option + Space")
                LabeledContent("系统权限", value: "不需要辅助功能或屏幕录制")
            }
            Section("本地文件") {
                LabeledContent("已暂存", value: "\(state.items.count) 个文件")
                Button("打开暂存文件夹") { NSWorkspace.shared.open(state.paths.staging) }
                Text("暂存区只保存本地副本。移除和清空不会删除原文件。飞书直接发送使用临时副本，结束后清理。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
    }
}

struct DiagnosticsSettings: View {
    @Bindable var state: AppState
    var body: some View {
        Form {
            Section("Super Input") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0")
                LabeledContent("支持的软件", value: "飞书")
                Link("开源仓库 · MIT License", destination: SetupGuide.repositoryURL)
            }
            Section("配置检查") {
                if state.ruleStore.errors.isEmpty { Label("飞书配置已加载", systemImage: "checkmark.circle") }
                ForEach(state.ruleStore.errors, id: \.self) { Text($0).foregroundStyle(.orange).textSelection(.enabled) }
                Button("打开本机配置目录") { NSWorkspace.shared.open(state.paths.rules) }
                Text("本机配置与 CLI 凭据独立。这个版本只加载 feishu.json；旧软件的配置文件留在本机，不参与运行。").font(.caption).foregroundStyle(.secondary)
            }
            Section("反馈问题") {
                Text("请提供 App 版本、macOS 版本、lark-cli 版本和复现步骤。截图前隐藏账号、联系人、会话标识和认证信息。").fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
    }
}

struct FeishuSettings: View {
    @Bindable var state: AppState
    @State private var search = ""
    @State private var cliPath = ""
    @State private var error = ""
    @State private var auth: FeishuAuthorization?
    @State private var authorizing = false
    var body: some View {
        Form {
            Section("飞书 · 拖到会话直接发送") {
                Text("把文件拖到菜单栏图标下方，移到接收框上半区展开两列授权会话。松手到卡片即以你本人身份发送，原文件保留。").fixedSize(horizontal: false, vertical: true)
                Toggle("启用飞书直接发送", isOn: Binding(get: { state.feishuConfiguration.enabled }, set: { value in change { $0.enabled = value } }))
                LabeledContent("已授权会话", value: "\(state.feishuConfiguration.destinations.count) 个")
            }
            Section("账号与 CLI") {
                TextField("CLI 路径", text: $cliPath).textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存路径") { change { $0.cliPath = cliPath } }
                    Button("读取会话 / 检查连接") { Task { await state.refreshFeishu() } }.disabled(state.feishuRefreshing)
                    if state.feishuRefreshing { ProgressView().controlSize(.small) }
                }
                Text(state.feishuDirectoryMessage).font(.caption).foregroundStyle(.secondary)
                Button("登录 / 补齐飞书权限…") {
                    authorizing = true; auth = nil
                    Task {
                        defer { authorizing = false }
                        do { auth = try await FeishuCLI().beginAuthorization(cliPath: state.feishuConfiguration.cliPath) }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(authorizing || state.feishuRefreshing || state.transferBusy)
                if let account = state.feishuAccount {
                    LabeledContent("发送身份", value: "本人 · \(account.name)")
                    LabeledContent("发送权限", value: account.canSend ? "已开启" : "尚未开启")
                }
                if let auth {
                    if let url = URL(string: auth.url) { Link("打开飞书授权页面", destination: url) }
                    if let image = NSImage(data: auth.qrPNG) { Image(nsImage: image).resizable().interpolation(.none).frame(width: 160, height: 160) }
                    Button("我已完成授权，检查连接") {
                        authorizing = true
                        Task {
                            defer { authorizing = false }
                            do { try await FeishuCLI().finishAuthorization(auth, cliPath: state.feishuConfiguration.cliPath); self.auth = nil; await state.refreshFeishu() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(authorizing)
                }
            }
            Section("已授权 · 拖放列表按此顺序排列") {
                if state.feishuConfiguration.destinations.isEmpty { Text("还没有授权会话，请在下方勾选。读取会话不会自动开启发送。").font(.caption).foregroundStyle(.secondary) }
                ForEach(state.feishuConfiguration.destinations) { destination in
                    HStack {
                        ConversationAvatar(destination: destination).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 3) { Text(destination.name); Text(destination.identityHint).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { move(destination, by: -1) } label: { Image(systemName: "arrow.up") }.help("上移")
                        Button { move(destination, by: 1) } label: { Image(systemName: "arrow.down") }.help("下移")
                        Button("移除授权") { do { try state.authorizeFeishu(destination, allowed: false) } catch { self.error = error.localizedDescription } }
                    }.buttonStyle(.borderless)
                }
            }
            Section("添加允许直接发送的会话") {
                HStack {
                    TextField("搜索联系人或会话名称", text: $search).onSubmit { Task { await state.refreshFeishu(query: search) } }
                    Button("搜索") { Task { await state.refreshFeishu(query: search) } }.disabled(state.feishuRefreshing)
                }
                ForEach(state.feishuDirectory) { destination in
                    Toggle(isOn: Binding(get: { state.feishuConfiguration.destinations.contains(where: { $0.id == destination.id }) }, set: { allowed in
                        do { try state.authorizeFeishu(destination, allowed: allowed) } catch { self.error = error.localizedDescription }
                    })) {
                        HStack(spacing: 10) {
                            ConversationAvatar(destination: destination).frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 3) { Text(destination.name); Text(destination.identityHint).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("独立规则") {
                Button("打开飞书 JSON 配置") { if let rule = state.ruleStore.rules.first(where: { $0.id == "feishu" }) { NSWorkspace.shared.open(state.ruleStore.fileURL(for: rule)) } }
                Text("授权会话与账号绑定保存在 feishu.json；只由这台 Mac 的 App 使用，更新应用会保留配置。CLI 负责登录信息，App 不存储令牌。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
        .task { cliPath = state.feishuConfiguration.cliPath.isEmpty ? FeishuCLI.defaultPath : state.feishuConfiguration.cliPath; if state.feishuAccount == nil { await state.refreshFeishu() } }
        .alert("飞书", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("好") { error = "" } } message: { Text(error) }
    }
    func change(_ update: (inout FeishuSendConfiguration) -> Void) {
        var config = state.feishuConfiguration; update(&config)
        do { try state.saveFeishu(config) } catch { self.error = error.localizedDescription }
    }
    func move(_ destination: FeishuDestination, by delta: Int) {
        change { config in
            guard let index = config.destinations.firstIndex(of: destination), config.destinations.indices.contains(index + delta) else { return }
            config.destinations.swapAt(index, index + delta)
        }
    }
}
