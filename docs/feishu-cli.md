# 飞书 CLI 配置教程

Super Input 通过官方 [lark-cli](https://github.com/larksuite/cli) 发送附件。连接的是你的用户账号和稳定会话 ID；不定位、粘贴或点击飞书客户端输入框。无需辅助功能与屏幕录制权限。

## 1. 安装

安装 Node.js 和 npm（建议当前 LTS；CLI 要求 Node.js ≥16），然后运行：

```bash
npm install -g @larksuite/cli
lark-cli --version
command -v lark-cli
```

已有安装可复用。本版验证过 1.0.98；其他版本命令以 `--help` 为准。不要在仓库里保存或提交 CLI 登录资料。

## 2. 创建或复用应用配置

先用 `lark-cli auth status --json --verify` 检查现有配置。若已可用，直接复用。

尚未配置应用时：

```bash
lark-cli config init --new
```

命令会等待你在浏览器中完成配置，按照返回的链接与官方提示操作。应用在开发者后台的权限与用户侧授权都要满足。如果在 Agent 工作区中提示使用 `config bind`，先查 `lark-cli config bind --help`，按官方流程绑定现有应用；不要强制覆盖已有配置。

## 3. 登录用户身份与授权

普通用户在终端运行：

```bash
lark-cli auth login --domain im --domain contact
lark-cli auth status --json --verify
```

使用 IM 与通讯录业务范围是为了查询会话、联系人和以本人身份发送文件。本人发送需 `im:message.send_as_user`。若缺少 scope，按 CLI 返回的 `missing_scopes` 和 `console_url` 到开发者后台补齐，再重新授权。

确认 `identities.user.available=true`、`identities.user.verified=true`，存在用户 `openId` 和应用 `appId`。已通过服务器验证的 `needs_refresh` 状态可以由 CLI 自动刷新；不需要因此反复重新登录。机器人身份不能替代用户身份。

只读检查会话：

```bash
lark-cli im +chat-list --as user --types p2p,group --sort active_time --page-size 20 --format json
```

业务命令成功以 `ok=true` 判断，不按顶层 `code=0` 判断。

## 4. 连接 Super Input

打开“设置 → 飞书”，将 `command -v lark-cli` 的完整输出填入 CLI 路径，点“保存路径”与“读取会话 / 检查连接”。首次授权也可用本页“登录 / 补齐飞书权限…”按钮，打开原始授权链接或扫描二维码，完成后点“我已完成授权，检查连接”。

勾选允许直接发送的联系人或群聊，并用上下箭头排序。列表绑定当前账号和飞书应用。读取列表不会自动勾选会话。

## 5. 使用

把文件拖到菜单栏图标下方，移到接收框上半区展开两列会话，松手到授权卡片直接发送。每个文件最大 30 MiB，可拖截图和多文件。文件夹、软件包、符号链接请先展开或压缩。暂存区里的缩略图可重新拖到会话卡片。

首次使用可选择自己的会话手动验证。授权会话卡片意味着直接发送，不是未发送草稿。

## 常见问题

| 问题 | 处理 |
|---|---|
| 终端能用，App 找不到 CLI | 填入完整 CLI 路径并保存。 |
| App 找不到 Node | Finder 启动不继承终端 PATH；推荐 Node 与 lark-cli 在同一个 bin 目录。App 会补充 CLI 所在目录、常见安装目录，不修改全局环境。 |
| 本人发送权限缺失 | 补齐开发者后台权限，再登录授权 IM 业务范围。 |
| 只读身份为 bot | 重新进行用户授权；发送调用明确使用 `--as user`。 |
| 读取会话失败 | 查看 CLI 的缺少权限提示；检查 IM 和通讯录范围，以及当前版本的命令参数。 |
| 账号发生变化 | 移除旧账号会话，再刷新和勾选新账号会话。 |
| 多文件发送中断或结果不明 | 先到飞书检查已经收到的附件；App 不自动重发整批文件。 |
| CLI 要求额外高风险确认 | App 停止操作；由用户查看请求后决定，不自动追加确认参数。 |

本机文件 `~/Library/Application Support/SuperInputDemo/Rules/feishu.json` 包含账号与会话标识，仅留在本机。App 不保存访问令牌；CLI 自己管理登录与刷新。Agent 的授权流程见 [agent-setup.md](agent-setup.md)。
