import Foundation

enum SetupGuide {
    static let cliURL = URL(string: "https://github.com/larksuite/cli")!
    static let repositoryURL = URL(string: "https://github.com/HR2AY/super-input")!
    static let install = "npm install -g @larksuite/cli"
    static let inspect = "lark-cli --version\ncommand -v lark-cli"
    static let initialize = "lark-cli config init --new"
    static let login = "lark-cli auth login --domain im --domain contact"
    static let verify = "lark-cli auth status --json --verify"
    static let conversations = "lark-cli im +chat-list --as user --types p2p,group --sort active_time --page-size 20 --format json"
    static let agent = """
    请帮我配置 Super Input 的飞书接入。

    Super Input 是 macOS 菜单栏文件发送工具。飞书通道通过官方 lark-cli，以本人身份向用户勾选的会话发送文件；不操控飞书客户端输入框，不需要辅助功能或屏幕录制权限。

    1. 检查现有 Node.js、npm 与 lark-cli，复用已安装的 CLI 和已有应用配置。CLI 的 npm 安装要求 Node.js 16 或更新版本，建议使用当前 LTS。官方仓库：https://github.com/larksuite/cli 。此版本已验证 lark-cli 1.0.98。
       npm install -g @larksuite/cli
       lark-cli --version
       command -v lark-cli
    2. 先执行 lark-cli auth status --json --verify，判断是否已有可用用户身份。不要显示 app secret、access token、refresh token，也不要读取或复制认证文件到仓库。
    3. 只有尚未配置飞书应用时，才执行 lark-cli config init --new；这个命令会等待用户完成浏览器配置。Agent 应在后台启动，取得命令返回的原始配置链接，生成二维码并交给用户操作。不要覆盖已有配置；若在 Agent 工作区中被要求 config bind，先查看 lark-cli config bind --help，按官方流程绑定现有应用，不自行强制创建。
    4. 缺少用户登录或 IM / 通讯录权限时，使用分步授权：
       lark-cli auth login --domain im --domain contact --no-wait --json
       把命令返回的原始 verification_url 给用户，使用 lark-cli auth qrcode <原始URL> --output authorization.png 生成二维码（输出路径相对当前目录）。等待用户确认完成，再执行 lark-cli auth login --device-code <本次device_code> --json。
       开发者后台的应用权限与用户授权都必须满足；根据 CLI 返回的 missing_scopes 和 console_url 补齐缺少的权限。不要省略授权范围。
    5. 只读验证：
       lark-cli auth status --json --verify
       lark-cli im +chat-list --as user --types p2p,group --sort active_time --page-size 20 --format json
       可确认用户身份和本人发送权限 im:message.send_as_user；用户状态应为可用、已验证。业务命令成功以 ok=true 判断，不按顶层 code=0 判断。
    6. 在 Super Input → 设置 → 飞书中保存 command -v lark-cli 返回的完整路径，然后点“读取会话 / 检查连接”。让用户亲自勾选允许直接发送的会话；会话列表绑定当前用户和飞书应用。不要替用户勾选或发送测试消息。
    7. 用户把文件拖到菜单栏飞书图标下方，移到接收框上半区展开两列会话，松手到授权卡片直接发送。每个文件最多 30 MiB；文件夹、软件包、符号链接不支持。截图和多文件可拖入。CLI 文件路径必须相对执行目录，结果不明时停止，不自动重复发送。

    Finder 启动 App 不继承终端 PATH。若终端能运行而 App 提示找不到 Node，检查 CLI 路径与 Node 安装位置；推荐 Node 与 lark-cli 在同一个 bin 目录。Super Input 不修改全局 PATH。
    本机配置：~/Library/Application Support/SuperInputDemo/Rules/feishu.json 。此文件含账号和会话标识，仅供本机使用，不上传 GitHub。App 更新保留此文件。不要关闭系统安全机制。
    """
}
