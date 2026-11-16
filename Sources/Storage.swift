import AppKit
import Foundation
import Observation

struct AppPaths {
    let root: URL
    var rules: URL { root.appendingPathComponent("Rules", isDirectory: true) }
    var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    var manifest: URL { root.appendingPathComponent("staging.json") }
    static var standard: AppPaths {
        AppPaths(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SuperInputDemo", isDirectory: true))
    }
    func prepare() throws {
        for url in [root, rules, staging] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
}

@MainActor @Observable
final class RuleStore {
    private(set) var rules: [AppRule] = []
    private(set) var errors: [String] = []
    let paths: AppPaths
    let templates: URL
    init(paths: AppPaths = .standard, templates: URL? = nil) {
        self.paths = paths
        self.templates = templates ?? Bundle.main.resourceURL!.appendingPathComponent("Rules")
        do { try paths.prepare(); try installMissingTemplates(); reload() }
        catch { errors = [error.localizedDescription] }
    }
    func installMissingTemplates() throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: templates, includingPropertiesForKeys: nil)) ?? []
        for source in files where source.pathExtension == "json" {
            let destination = paths.rules.appendingPathComponent(source.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
        }
    }
    func reload() {
        var next: [AppRule] = [], problems: [String] = [], ids = Set<String>()
        let files = ((try? FileManager.default.contentsOfDirectory(at: paths.rules, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files where file.lastPathComponent == "feishu.json" {
            do {
                let rule = try JSONDecoder().decode(AppRule.self, from: Data(contentsOf: file)).validated()
                guard file.deletingPathExtension().lastPathComponent == rule.id else { throw RuleError.invalid("文件名必须与规则 ID 一致") }
                guard ids.insert(rule.id).inserted else { throw RuleError.invalid("重复规则 ID：\(rule.id)") }
                next.append(rule)
            } catch { problems.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
        }
        // An invalid reload disables that target; an obsolete valid rule must not keep running.
        rules = next
        errors = problems
    }
    func fileURL(for rule: AppRule) -> URL { paths.rules.appendingPathComponent(rule.id + ".json") }
    func save(_ rule: AppRule) throws {
        let valid = try rule.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(valid).write(to: fileURL(for: valid), options: .atomic)
        reload()
    }
    func restore(_ id: String) throws {
        let source = templates.appendingPathComponent(id + ".json")
        guard FileManager.default.fileExists(atPath: source.path) else { throw RuleError.invalid("这是自定义规则，没有内置模板") }
        let rule = try JSONDecoder().decode(AppRule.self, from: Data(contentsOf: source))
        try save(rule)
    }
}

actor FileStager {
    let paths: AppPaths
    init(paths: AppPaths) { self.paths = paths }
    func stage(_ source: URL, ownedTemporary: Bool = false) throws -> StagedItem {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ImportFailure.stopped("首版只接收普通文件，请先展开文件夹或软件包") }
        let id = UUID(), folder = paths.staging.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return StagedItem(id: id, relativePath: "Staging/\(id.uuidString)/\(source.lastPathComponent)", originalPath: ownedTemporary ? nil : source.standardizedFileURL.path, fileName: source.lastPathComponent, byteCount: Int64(values.fileSize ?? 0), createdAt: Date())
    }
    func stageImage(_ data: Data) throws -> StagedItem {
        let temporary = paths.root.appendingPathComponent("image-\(UUID().uuidString).png")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try stage(temporary, ownedTemporary: true)
    }
}

@MainActor @Observable
final class AppState {
    let paths: AppPaths
    let ruleStore: RuleStore
    let stager: FileStager
    private(set) var items: [StagedItem] = []
    var selectedTarget = "feishu"
    var isStaging = false
    var isImporting: Bool { feishuSending }
    var message = "拖入文件暂存，再把缩略图拖到飞书会话卡片发送"
    var onRulesChanged: (() -> Void)?
    var requestSettings: ((String?) -> Void)?
    var feishuAccount: FeishuAccount?
    var feishuDirectory: [FeishuDestination] = []
    var feishuDirectoryMessage = "读取飞书会话后，勾选允许直接发送的目标"
    var feishuRefreshing = false
    var feishuTransfer: FeishuTransfer?
    var onFeishuTransferChanged: (() -> Void)?
    var feishuTransport: any FeishuTransporting = FeishuCLI()
    #if SUPERINPUT_UI_TEST
    var feishuTestConfiguration: FeishuSendConfiguration?
    #endif
    init(paths: AppPaths = .standard, templates: URL? = nil) {
        self.paths = paths
        ruleStore = RuleStore(paths: paths, templates: templates)
        stager = FileStager(paths: paths)
        if let data = try? Data(contentsOf: paths.manifest), let saved = try? JSONDecoder().decode([StagedItem].self, from: data) {
            items = saved.filter { $0.hasSafeCachePath && FileManager.default.fileExists(atPath: paths.root.appendingPathComponent($0.relativePath).path) }
        }
    }
    var selectedRule: AppRule? { ruleStore.rules.first }
    var transferBusy: Bool { feishuSending }
    var feishuConfiguration: FeishuSendConfiguration {
        #if SUPERINPUT_UI_TEST
        if let feishuTestConfiguration { return feishuTestConfiguration }
        #endif
        guard let rule = ruleStore.rules.first(where: { $0.id == "feishu" }) else { return .init(enabled: false) }
        var config = rule.feishuSend ?? .init()
        config.enabled = config.enabled && rule.enabled
        return config
    }
    var feishuDestinations: [FeishuDestination] { feishuConfiguration.enabled ? feishuConfiguration.destinations : [] }
    var feishuSending: Bool { feishuTransfer?.status == .sending || feishuTransfer?.status == .receiving }
    func saveFeishu(_ config: FeishuSendConfiguration) throws {
        guard !feishuSending else { throw RuleError.invalid("文件正在发送，请完成后再修改配置") }
        guard var rule = ruleStore.rules.first(where: { $0.id == "feishu" }) else { throw RuleError.invalid("飞书规则未加载") }
        rule.feishuSend = config; rule.enabled = config.enabled; try ruleStore.save(rule); onRulesChanged?()
    }
    func refreshFeishu(query: String? = nil) async {
        guard !feishuRefreshing, !feishuSending else { return }
        feishuRefreshing = true; feishuDirectoryMessage = "正在读取飞书会话…"
        defer { feishuRefreshing = false }
        do {
            let config = feishuConfiguration
            let account = try await feishuTransport.account(cliPath: config.cliPath)
            guard feishuConfiguration == config else { return }
            feishuAccount = account
            let directory = try await feishuTransport.conversations(cliPath: config.cliPath, query: query)
            guard feishuConfiguration == config else { return }
            feishuDirectory = directory
            feishuDirectoryMessage = account.canSend ? "已连接 \(account.name) · 勾选会话后，拖入卡片即以本人身份发送" : "已连接 \(account.name) · 还需开启本人发送权限"
        } catch { feishuDirectory = []; feishuDirectoryMessage = error.localizedDescription }
    }
    func authorizeFeishu(_ destination: FeishuDestination, allowed: Bool) throws {
        var config = feishuConfiguration
        if allowed {
            guard let account = feishuAccount else { throw RuleError.invalid("请先读取当前飞书账号") }
            guard config.destinations.isEmpty || (config.accountOpenID == account.openID && config.appID == account.appID) else { throw RuleError.invalid("飞书账号已变化，请先移除旧账号的授权会话") }
            config.accountOpenID = account.openID; config.appID = account.appID
            if !config.destinations.contains(where: { $0.id == destination.id }) { config.destinations.append(destination) }
        } else { config.destinations.removeAll { $0.id == destination.id } }
        try saveFeishu(config)
    }
    func sendFeishu(_ sources: [URL], to destination: FeishuDestination) async {
        guard feishuTransfer?.status != .sending else { return }
        let config = feishuConfiguration
        guard config.enabled, config.destinations.contains(where: { $0 == destination }), !sources.isEmpty else { return }
        feishuTransfer = .init(status: .sending, recipient: destination.name, detail: "正在核对飞书账号…"); onFeishuTransferChanged?()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperInput-Transfer-" + UUID().uuidString, isDirectory: true)
        var receipts: [String] = []
        defer { try? FileManager.default.removeItem(at: folder); onFeishuTransferChanged?() }
        do {
            try config.validate()
            let account = try await feishuTransport.account(cliPath: config.cliPath)
            guard account.openID == config.accountOpenID, account.appID == config.appID else { throw RuleError.invalid("当前飞书账号与授权会话不匹配，请在设置里重新授权会话") }
            guard account.canSend else { throw RuleError.invalid("飞书尚未授予本人发送权限，请在设置里开启") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var copies: [URL] = []
            // Freeze the complete batch before transmitting any file. This also
            // takes ownership of ephemeral screenshots until upload finishes.
            for source in sources {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RuleError.invalid("只接收普通文件，请先展开文件夹或软件包") }
                guard let size = values.fileSize, size <= 30 * 1024 * 1024 else { throw RuleError.invalid("首版飞书直接发送支持单个文件不超过 30 MB") }
                let own = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
                let copy = own.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: copy); copies.append(copy)
            }
            for (index, file) in copies.enumerated() {
                guard feishuConfiguration.enabled, feishuConfiguration.destinations.contains(destination) else { throw RuleError.invalid("该会话的直接发送授权已被移除") }
                feishuTransfer?.detail = "正在发送 \(index + 1)/\(copies.count) · \(file.lastPathComponent)"; onFeishuTransferChanged?()
                let receipt = try await feishuTransport.send(file: file, destination: destination, key: UUID().uuidString, cliPath: config.cliPath)
                receipts.append(receipt.messageID)
            }
            feishuTransfer = .init(status: .sent, recipient: destination.name, detail: "已发送 \(copies.count) 个文件", messageIDs: receipts)
        } catch {
            let uncertain = (error as? FeishuCLIError)?.uncertain == true
            let prefix = receipts.isEmpty ? "" : "已发送 \(receipts.count) 个文件；"
            feishuTransfer = .init(status: uncertain ? .uncertain : .failed, recipient: destination.name, detail: prefix + error.localizedDescription, messageIDs: receipts)
        }
    }
    func fileURL(_ item: StagedItem) -> URL { paths.root.appendingPathComponent(item.relativePath) }
    func persist() {
        do { try JSONEncoder().encode(items).write(to: paths.manifest, options: .atomic) }
        catch { message = "暂存清单保存失败：\(error.localizedDescription)" }
    }
    func stage(_ urls: [URL], target: String?, autoImport: Bool) async {
        guard !isStaging else { message = "正在接收上一批文件，请稍后"; return }
        isStaging = true; message = "正在暂存 \(urls.count) 个文件…"
        var added: [UUID] = [], failures: [String] = []
        for url in urls {
            if let existing = items.first(where: { $0.originalPath == url.standardizedFileURL.path }) {
                if !existing.status.blocksRetry { added.append(existing.id) }
                continue
            }
            do { let item = try await stager.stage(url); items.append(item); added.append(item.id) }
            catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        isStaging = false; persist()
        message = failures.isEmpty ? "已暂存 \(added.count) 个文件" : failures.joined(separator: "\n")
        if let target { selectedTarget = target }
        // A partially failed batch stays local; do not silently import only its successful half.
        // The shelf only stores files; sending always requires an explicit conversation drop.
    }
    func stageImage(_ data: Data, target: String?, autoImport: Bool) async {
        guard !isStaging else { return }
        isStaging = true
        do {
            let item = try await stager.stageImage(data); items.append(item); persist()
            isStaging = false
            if let target { selectedTarget = target }
            message = "截图已暂存"
            // A screenshot stays local until dropped onto an authorized conversation.
        } catch { isStaging = false; message = error.localizedDescription }
    }
    func remove(_ id: UUID) {
        guard !isImporting, let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }; persist()
        // Delete only the owned cache, never the original source.
        try? FileManager.default.removeItem(at: fileURL(item).deletingLastPathComponent())
    }
    func clear() { guard !isImporting else { return }; for id in items.map(\.id) { remove(id) }; message = "暂存区已清空，原文件保留" }
}
