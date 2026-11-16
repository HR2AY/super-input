import Foundation
import AppKit

enum TestFailure: Error { case failed(String), interrupted }

actor MockTransport: FeishuTransporting {
    var identity = FeishuAccount(openID: "ou_test_owner", name: "Test", appID: "cli_test_app", scopes: ["im:message.send_as_user"])
    var calls: [URL] = []
    var keys: [String] = []
    var failOn = 0
    func setOwner(_ value: String) { identity.openID = value }
    func fail(_ value: Int) { failOn = value }
    func reset() { calls = []; keys = [] }
    func account(cliPath: String) async throws -> FeishuAccount { identity }
    func conversations(cliPath: String, query: String?) async throws -> [FeishuDestination] { [] }
    func send(file: URL, destination: FeishuDestination, key: String, cliPath: String) async throws -> FeishuReceipt {
        calls.append(file); keys.append(key)
        guard FileManager.default.fileExists(atPath: file.path) else { throw TestFailure.failed("copy unavailable") }
        if calls.count == failOn { throw FeishuCLIError(message: "test timeout", uncertain: true) }
        return .init(messageID: "om_test_\(calls.count)")
    }
}

actor CommandStub {
    var outputs: [CLIOutput]
    var calls: [[String]] = []
    var directories: [URL?] = []
    init(_ outputs: [CLIOutput]) { self.outputs = outputs }
    func run(_ args: [String], _ path: String, _ cwd: URL?, _ timeout: TimeInterval) throws -> CLIOutput {
        calls.append(args); directories.append(cwd)
        guard !outputs.isEmpty else { throw TestFailure.interrupted }
        return outputs.removeFirst()
    }
}

@main
struct FeishuChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure.failed(message) }
        count += 1
    }
    static func output(_ object: [String: Any], status: Int32 = 0, timeout: Bool = false) throws -> CLIOutput {
        .init(stdout: try JSONSerialization.data(withJSONObject: object), stderr: Data(), status: status, timedOut: timeout)
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SuperInput-Checks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let templates = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Rules")
        let paths = AppPaths(root: root.appendingPathComponent("data"))
        let state = AppState(paths: paths, templates: templates)
        let mock = MockTransport()
        state.feishuTransport = mock
        try check(state.ruleStore.rules.map(\.id) == ["feishu"], "fresh install has exactly one adapter")
        try check(state.feishuDestinations.isEmpty && state.feishuConfiguration.accountOpenID.isEmpty, "public template has no user identity or authorized recipients")
        // Old, even malformed, adapter files must not affect the Feishu release.
        let obsolete = paths.rules.appendingPathComponent("obsolete.json")
        try Data("invalid old plugin config".utf8).write(to: obsolete)
        state.ruleStore.reload()
        try check(state.ruleStore.rules.count == 1 && state.ruleStore.errors.isEmpty, "unrelated saved adapters are not parsed")
        try check(fm.fileExists(atPath: obsolete.path), "unrelated user files are preserved")
        let destination = FeishuDestination(identifier: "oc_test_chat", kind: .chat, name: "Test chat", subtitle: "Fixture")
        let other = FeishuDestination(identifier: "oc_test_other", kind: .chat, name: "Other", subtitle: "Fixture")
        let config = FeishuSendConfiguration(enabled: true, cliPath: "", accountOpenID: "ou_test_owner", appID: "cli_test_app", destinations: [destination])
        try state.saveFeishu(config)
        let restored = AppState(paths: paths, templates: templates)
        try check(restored.feishuConfiguration == config, "existing account and recipients survive restart")
        let file = root.appendingPathComponent("测试 文件.txt")
        let bytes = Data("local fixture".utf8)
        try bytes.write(to: file)
        await state.sendFeishu([file], to: other)
        try check(await mock.calls.isEmpty, "unapproved destination causes zero sends")
        await mock.setOwner("ou_different_owner")
        await state.sendFeishu([file], to: destination)
        try check(await mock.calls.isEmpty && state.feishuTransfer?.status == .failed, "account mismatch stops before upload")
        await mock.setOwner("ou_test_owner")
        await state.sendFeishu([file], to: destination)
        try check(state.feishuTransfer?.status == .sent && state.feishuTransfer?.messageIDs == ["om_test_1"], "receipt determines successful sending")
        let sentCopy = await mock.calls[0]
        try check(sentCopy != file && !fm.fileExists(atPath: sentCopy.path), "owned upload copy is cleaned after sending")
        try check(try Data(contentsOf: file) == bytes, "original file is preserved")
        await mock.reset()
        let link = root.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        await state.sendFeishu([file, link], to: destination)
        try check(await mock.calls.isEmpty, "whole batch validates before first upload")
        await state.sendFeishu([root], to: destination)
        try check(await mock.calls.isEmpty, "directories cannot be sent")
        await mock.fail(2)
        await state.sendFeishu([file, file], to: destination)
        try check(state.feishuTransfer?.status == .uncertain, "partial timeout is reported as uncertain")
        try check(state.feishuTransfer?.messageIDs == ["om_test_1"], "partial success retains previous receipt")
        let partialCalls = await mock.calls
        let partialKeys = await mock.keys
        try check(partialCalls.count == 2 && Set(partialKeys).count == 2, "each file uses a separate key and never automatically retries")
        state.feishuTransfer = .init(status: .sending, recipient: "Test", detail: "Fixture")
        do { try state.saveFeishu(config); throw TestFailure.failed("settings changed during send") }
        catch is RuleError { try check(true, "configuration is frozen during active send") }
        state.feishuTransfer = nil
        await state.stage([file], target: "feishu", autoImport: true)
        let shelfSendCount = await mock.calls.count
        try check(state.items.count == 1 && shelfSendCount == 2, "shelf intake never sends even with legacy autoImport input")
        let staged = state.fileURL(state.items[0])
        state.clear()
        try check(!fm.fileExists(atPath: staged.path) && fm.fileExists(atPath: file.path), "clearing only removes owned staged copies")
        // Geometry shares the exact production hit testing.
        try check(FeishuGridGeometry.rows(5) == 3, "five recipients occupy 2/2/1")
        try check(FeishuGridGeometry.index(at: .init(x: 40, y: 180), count: 5, firstRow: 0, visibleRows: 3) == 0, "first card is actionable")
        try check(FeishuGridGeometry.index(at: .init(x: 160, y: 180), count: 5, firstRow: 0, visibleRows: 3) == nil, "column gap never sends")
        try check(FeishuGridGeometry.index(at: .init(x: 200, y: 320), count: 5, firstRow: 0, visibleRows: 3) == nil, "empty last card never sends")
        try check(FeishuGridGeometry.index(at: .init(x: 40, y: 180), count: 7, firstRow: 1, visibleRows: 2) == 2, "scrolling maps to correct stable recipient")
        var hover = ConversationHoverGate()
        hover.update(onTarget: true, inside: true, onEntryZone: false, time: 1)
        try check(hover.iconVisible && !hover.listExpanded, "icon appears immediately on entry")
        hover.update(onTarget: true, inside: true, onEntryZone: true, time: 2)
        try check(hover.listExpanded && hover.listExpandedAt == 2, "upper zone expands recipient list")
        hover.update(onTarget: false, inside: true, onEntryZone: true, time: 3)
        try check(!hover.listExpanded, "leaving target resets drop gate")

        let auth = try output(["appId": "cli_test_app", "identities": ["user": ["available": true, "verified": true, "status": "needs_refresh", "openId": "ou_test_owner", "scope": "im:message.send_as_user"]]])
        let account = try FeishuCLI.accountResult(auth)
        try check(account.canSend, "server-verified needs_refresh is accepted")
        let unverified = try output(["appId": "cli_test_app", "identities": ["user": ["available": true, "verified": false, "openId": "ou_test_owner"]]])
        do { _ = try FeishuCLI.accountResult(unverified); throw TestFailure.failed("unverified auth accepted") }
        catch is FeishuCLIError { try check(true, "unverified user is rejected") }
        let receipt = try output(["ok": true, "identity": "user", "data": ["message_id": "om_test_receipt"]])
        let stub = CommandStub([auth, receipt])
        let cli = FeishuCLI(runner: { try await stub.run($0, $1, $2, $3) })
        _ = try await cli.account(cliPath: "/fixture/lark-cli")
        let result = try await cli.send(file: file, destination: destination, key: "fixture-key", cliPath: "/fixture/lark-cli")
        try check(result.messageID == "om_test_receipt", "CLI message receipt is parsed")
        let commands = await stub.calls
        try check(commands[0] == ["auth", "status", "--json", "--verify"], "auth is verified against the server")
        try check(commands[1] == ["im", "+messages-send", "--as", "user", "--chat-id", destination.identifier, "--file", "./测试 文件.txt", "--idempotency-key", "fixture-key", "--format", "json"], "send uses direct argv, explicit identity and relative unicode file path")
        try check(await stub.directories[1] == file.deletingLastPathComponent(), "CLI file path is relative to its cwd")
        for invalid in [try output(["code": 0, "data": ["message_id": "om_wrong"]]), try output(["ok": true, "identity": "bot", "data": ["message_id": "om_wrong"]]), try output(["ok": true, "identity": "user", "data": [:]]), try output([:], status: 1, timeout: true)] {
            let broken = CommandStub([invalid])
            do { _ = try await FeishuCLI(runner: { try await broken.run($0, $1, $2, $3) }).send(file: file, destination: destination, key: "test", cliPath: ""); throw TestFailure.failed("invalid receipt accepted") }
            catch let e as FeishuCLIError { try check(e.uncertain, "invalid or missing receipt stays uncertain") }
            try check(await broken.calls.count == 1, "failed CLI send is never retried")
        }
        let interrupted = CommandStub([])
        do { _ = try await FeishuCLI(runner: { try await interrupted.run($0, $1, $2, $3) }).send(file: file, destination: destination, key: "test", cliPath: ""); throw TestFailure.failed("interruption accepted") }
        catch let e as FeishuCLIError { try check(e.uncertain, "subprocess interruption stays uncertain") }
        let env = FeishuCLI.launchEnvironment(base: ["PATH": "/usr/bin:/bin"], executable: URL(fileURLWithPath: "/fixture/bin/lark-cli"))
        try check(env["PATH"]?.contains("/fixture/bin") == true, "Finder launch includes CLI sibling runtime directory")
        print("PASS: \(count) Feishu checks; no live CLI, user credentials or messages accessed.")
    }
}
