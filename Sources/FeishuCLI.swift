import Foundation

struct FeishuCLIError: LocalizedError, Sendable {
    var message: String
    var uncertain = false
    var errorDescription: String? { message }
}
protocol FeishuTransporting: Sendable {
    func account(cliPath: String) async throws -> FeishuAccount
    func conversations(cliPath: String, query: String?) async throws -> [FeishuDestination]
    func send(file: URL, destination: FeishuDestination, key: String, cliPath: String) async throws -> FeishuReceipt
}
struct FeishuAuthorization: Sendable {
    var url: String
    var deviceCode: String
    var qrPNG: Data
}
struct CLIOutput: Sendable { var stdout: Data; var stderr: Data; var status: Int32; var timedOut: Bool }

actor FeishuCLI: FeishuTransporting {
    typealias Runner = @Sendable ([String], String, URL?, TimeInterval) async throws -> CLIOutput
    private let runner: Runner?
    init(runner: Runner? = nil) { self.runner = runner }
    static var defaultPath: String {
        let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/lark-cli").path, "/opt/homebrew/bin/lark-cli", "/usr/local/bin/lark-cli"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? paths[0]
    }
    static func launchEnvironment(base: [String: String], executable: URL) -> [String: String] {
        var env = base
        let userRoot = FileManager.default.homeDirectoryForCurrentUser
        // Finder-launched apps do not inherit the user's shell PATH. The CLI's
        // npm launcher needs `node`, usually beside the resolved CLI symlink.
        let folders = [executable.resolvingSymlinksInPath().deletingLastPathComponent().path,
                       executable.deletingLastPathComponent().path,
                       userRoot.appendingPathComponent(".local/bin").path,
                       userRoot.appendingPathComponent(".local/nodejs/current/bin").path,
                       "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            + (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = folders.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        if (env["HOME"] ?? "").isEmpty { env["HOME"] = userRoot.path }
        env["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"; env["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        return env
    }
    func run(_ args: [String], cliPath: String, cwd: URL? = nil, timeout: TimeInterval = 45) async throws -> CLIOutput {
        if let runner { return try await runner(args, cliPath, cwd, timeout) }
        let path = cliPath.isEmpty ? Self.defaultPath : cliPath
        return try await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: path) else { throw FeishuCLIError(message: "找不到飞书 CLI，请在设置里填写 lark-cli 的完整路径") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperInput-CLI-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let outURL = folder.appendingPathComponent("out"), errURL = folder.appendingPathComponent("err")
            FileManager.default.createFile(atPath: outURL.path, contents: nil); FileManager.default.createFile(atPath: errURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
            defer { try? out.close(); try? err.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
            process.currentDirectoryURL = cwd ?? folder
            let env = Self.launchEnvironment(base: ProcessInfo.processInfo.environment, executable: URL(fileURLWithPath: path))
            process.environment = env; process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
            try process.run()
            let kill = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
            let started = Date(); process.waitUntilExit(); kill.cancel()
            return CLIOutput(stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL), status: process.terminationStatus, timedOut: Date().timeIntervalSince(started) >= timeout)
        }.value
    }
    static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    static func checked(_ result: CLIOutput, sending: Bool = false) throws -> [String: Any] {
        if result.timedOut { throw FeishuCLIError(message: sending ? "发送结果暂时无法确认，请在飞书检查后再决定是否重新拖入" : "飞书 CLI 请求超时，请稍后再试", uncertain: sending) }
        guard result.status == 0, let root = object(result.stdout), root["ok"] as? Bool == true else {
            let root = object(result.stderr) ?? object(result.stdout) ?? [:]
            let error = root["error"] as? [String: Any] ?? [:]
            if result.status == 10 { throw FeishuCLIError(message: "飞书 CLI 要求额外确认，操作已停止；请在 CLI 中检查该请求") }
            let message = error["message"] as? String ?? "飞书 CLI 没有返回可确认的结果"
            let type = error["type"] as? String ?? ""
            throw FeishuCLIError(message: message, uncertain: sending && (root["ok"] as? Bool != false || ["network", "transport", "timeout"].contains(type)))
        }
        if sending && root["identity"] as? String != "user" { throw FeishuCLIError(message: "发送身份不符合设置，操作已停止", uncertain: true) }
        if let identity = root["identity"] as? String, identity != "user" { throw FeishuCLIError(message: "操作身份不符合设置，已停止", uncertain: sending) }
        return root["data"] as? [String: Any] ?? [:]
    }
    func account(cliPath: String) async throws -> FeishuAccount {
        let result = try await run(["auth", "status", "--json", "--verify"], cliPath: cliPath)
        return try Self.accountResult(result)
    }
    static func accountResult(_ result: CLIOutput) throws -> FeishuAccount {
        if result.timedOut { throw FeishuCLIError(message: "检查飞书登录状态超时，请稍后再试") }
        guard result.status == 0 else {
            let object = Self.object(result.stderr) ?? Self.object(result.stdout)
            let error = object?["error"] as? [String: Any]
            if let message = error?["message"] as? String { throw FeishuCLIError(message: message) }
            let plain = String(data: result.stderr, encoding: .utf8) ?? ""
            if plain.contains("env: node:") { throw FeishuCLIError(message: "飞书 CLI 未找到 Node 运行环境，请检查 CLI 安装路径") }
            throw FeishuCLIError(message: "飞书 CLI 启动失败（退出码 \(result.status)），请检查设置中的路径")
        }
        guard let output = Self.object(result.stdout) else { throw FeishuCLIError(message: "飞书 CLI 返回的登录状态不是有效数据") }
        let root = output["data"] as? [String: Any] ?? output
        guard let identities = root["identities"] as? [String: Any], let user = identities["user"] as? [String: Any] else { throw FeishuCLIError(message: "飞书 CLI 返回的登录状态不完整，请检查 CLI 版本") }
        guard user["available"] as? Bool == true, user["verified"] as? Bool == true,
              let openID = user["openId"] as? String, openID.hasPrefix("ou_"),
              let appID = root["appId"] as? String, !appID.isEmpty else {
            throw FeishuCLIError(message: "请先登录并验证飞书 CLI 的用户账号")
        }
        return FeishuAccount(openID: openID, name: user["userName"] as? String ?? "飞书用户", appID: appID, scopes: Set((user["scope"] as? String ?? "").split(separator: " ").map(String.init)))
    }
    func conversations(cliPath: String, query: String?) async throws -> [FeishuDestination] {
        var rows: [FeishuDestination] = []
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let users = try Self.checked(await run(["contact", "+search-user", "--as", "user", "--query", query, "--page-size", "30", "--format", "json"], cliPath: cliPath))
            rows += Self.users(users)
        } else {
            let own = try Self.checked(await run(["contact", "+search-user", "--as", "user", "--user-ids", "me", "--format", "json"], cliPath: cliPath))
            rows += Self.users(own).map { var row = $0; row.subtitle = "我自己"; return row }
        }
        let chats = try Self.checked(await run(["im", "+chat-list", "--as", "user", "--types", "p2p,group", "--sort", "active_time", "--page-size", "100", "--page-all", "--page-limit", "5", "--format", "json"], cliPath: cliPath))
        for row in chats["chats"] as? [[String: Any]] ?? [] {
            guard row["chat_status"] as? String != "dissolved", let id = row["chat_id"] as? String else { continue }
            let name = row["name"] as? String ?? "会话"
            if let query, !query.isEmpty, !name.localizedCaseInsensitiveContains(query) { continue }
            rows.append(.init(identifier: id, kind: .chat, name: name, subtitle: row["chat_mode"] as? String == "p2p" ? "单聊" : "群聊", avatarURL: row["avatar"] as? String ?? ""))
        }
        var seen = Set<String>()
        return rows.filter { $0.isValid && seen.insert($0.id).inserted }
    }
    static func users(_ data: [String: Any]) -> [FeishuDestination] {
        (data["users"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["open_id"] as? String else { return nil }
            let chat = $0["p2p_chat_id"] as? String ?? ""
            return .init(identifier: chat.isEmpty ? id : chat, kind: chat.isEmpty ? .user : .chat, name: $0["localized_name"] as? String ?? id, subtitle: "单聊")
        }
    }
    static func sendArguments(file: URL, destination: FeishuDestination, key: String) -> [String] {
        ["im", "+messages-send", "--as", "user", destination.kind == .chat ? "--chat-id" : "--user-id", destination.identifier, "--file", "./" + file.lastPathComponent, "--idempotency-key", key, "--format", "json"]
    }
    func send(file: URL, destination: FeishuDestination, key: String, cliPath: String) async throws -> FeishuReceipt {
        guard destination.isValid else { throw FeishuCLIError(message: "会话 ID 无效，未发送") }
        let result: CLIOutput
        do { result = try await run(Self.sendArguments(file: file, destination: destination, key: key), cliPath: cliPath, cwd: file.deletingLastPathComponent(), timeout: 90) }
        catch { throw FeishuCLIError(message: "发送过程被中断，请先检查飞书会话，不会自动重试", uncertain: true) }
        let data = try Self.checked(result, sending: true)
        let nested = data["message"] as? [String: Any] ?? [:]
        guard let id = (data["message_id"] ?? nested["message_id"]) as? String, id.hasPrefix("om_") else { throw FeishuCLIError(message: "飞书没有返回消息凭据，请先检查会话，不会自动重试", uncertain: true) }
        return .init(messageID: id)
    }
    func beginAuthorization(cliPath: String) async throws -> FeishuAuthorization {
        let result = try await run(["auth", "login", "--domain", "im", "--domain", "contact", "--no-wait", "--json"], cliPath: cliPath)
        guard result.status == 0, let root = Self.object(result.stdout) else { throw FeishuCLIError(message: "无法生成飞书授权入口") }
        let data = root["data"] as? [String: Any] ?? root
        guard let url = (data["verification_url"] ?? data["verification_uri_complete"]) as? String, let code = data["device_code"] as? String else { throw FeishuCLIError(message: "飞书授权入口返回不完整") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperInput-Auth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let qr = try await run(["auth", "qrcode", url, "--output", "authorization.png"], cliPath: cliPath, cwd: folder)
        guard qr.status == 0 else { throw FeishuCLIError(message: "授权二维码生成失败") }
        return .init(url: url, deviceCode: code, qrPNG: try Data(contentsOf: folder.appendingPathComponent("authorization.png")))
    }
    func finishAuthorization(_ challenge: FeishuAuthorization, cliPath: String) async throws {
        let result = try await run(["auth", "login", "--device-code", challenge.deviceCode, "--json"], cliPath: cliPath, timeout: 45)
        guard result.status == 0 else { throw FeishuCLIError(message: "尚未完成授权或链接已过期，请重新开启授权") }
    }
}
