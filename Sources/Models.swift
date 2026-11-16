import AppKit
import Foundation

enum RuleError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

// Retain the original on-disk identity so existing Feishu authorization survives.
// Other adapters' fields are ignored by Codable and never loaded or executed.
struct AppRule: Codable, Identifiable, Equatable, Sendable {
    var schemaVersion = 1
    var id: String
    var name: String
    var bundleIdentifier: String
    var symbol: String
    var accent: String
    var enabled: Bool
    var feishuSend: FeishuSendConfiguration? = nil
    var targetLabel: String { "飞书授权会话" }
    func validated() throws -> AppRule {
        guard schemaVersion == 1, id == "feishu", !name.isEmpty else { throw RuleError.invalid("这个版本只加载飞书配置") }
        try feishuSend?.validate()
        return self
    }
}

enum ItemStatus: String, Codable, Sendable {
    case ready, importing, attached, pending, failed, uncertain
    var label: String {
        switch self {
        case .ready: return "已暂存"
        case .importing: return "正在放入输入框"
        case .attached: return "已放入 · 未发送"
        case .pending: return "等待你在目标窗口发送"
        case .failed: return "未导入"
        case .uncertain: return "请检查目标窗口"
        }
    }
    var blocksRetry: Bool { [.attached, .pending, .uncertain, .importing].contains(self) }
}

struct StagedItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var relativePath: String
    var originalPath: String?
    var fileName: String
    var byteCount: Int64
    var createdAt: Date
    var status: ItemStatus = .ready
    var lastTarget: String? = nil
    var detail: String = ""
    var hasSafeCachePath: Bool {
        !fileName.isEmpty && fileName != "." && fileName != ".." && !fileName.contains("/") &&
        relativePath == "Staging/\(id.uuidString)/\(fileName)"
    }
}

enum ImportFailure: LocalizedError {
    case stopped(String), uncertain(String)
    var errorDescription: String? {
        switch self { case .stopped(let m), .uncertain(let m): return m }
    }
}

enum DropGeometry {
    static let bodySize = CGSize(width: 320, height: 156)
    static let sensingSize = CGSize(width: 368, height: 224)
    static let menuGap: CGFloat = 8
    static func sensingFrame(anchor: CGRect, visibleFrame: CGRect, height: CGFloat = sensingSize.height) -> CGRect {
        let x = min(max(anchor.midX - sensingSize.width / 2, visibleFrame.minX + 8), visibleFrame.maxX - sensingSize.width - 8)
        return CGRect(x: x, y: anchor.minY - menuGap - height, width: sensingSize.width, height: height)
    }
    static func bodyFrame(in sensing: CGRect, height: CGFloat = bodySize.height) -> CGRect {
        CGRect(x: sensing.midX - bodySize.width / 2, y: sensing.maxY - height, width: bodySize.width, height: height)
    }
    static func targetIndex(x: CGFloat, body: CGRect, count: Int, previous: Int? = nil) -> Int? {
        guard count > 0 else { return nil }
        let slot = body.width / CGFloat(count)
        if let previous, (0..<count).contains(previous) {
            let left = body.minX + CGFloat(previous) * slot - 6
            let right = body.minX + CGFloat(previous + 1) * slot + 6
            if x >= left && x <= right { return previous }
        }
        return min(count - 1, max(0, Int(floor((x - body.minX) / slot))))
    }
    static func targetIndex(at point: CGPoint, header: CGRect, count: Int, previous: Int?, listExpanded: Bool) -> Int? {
        guard count > 0 else { return nil }
        if let previous, (0..<count).contains(previous),
           point.y >= header.midY || (listExpanded && point.y < header.minY) { return previous }
        return targetIndex(x: point.x, body: header, count: count, previous: previous)
    }
    static func isAppEntryZone(_ point: CGPoint, header: CGRect) -> Bool {
        header.contains(point) && point.y >= header.midY
    }
    static func normalizedPointer(_ point: CGPoint, body: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - body.minX) / body.width)), y: min(1, max(0, (body.maxY - point.y) / body.height)))
    }
}

struct FeishuDestination: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case chat, user }
    var identifier: String
    var kind: Kind
    var name: String
    var subtitle: String
    var avatarURL: String = ""
    var id: String { kind.rawValue + ":" + identifier }
    var isValid: Bool {
        let prefix = kind == .chat ? "oc_" : "ou_"
        return identifier.hasPrefix(prefix) && identifier.range(of: "^[a-zA-Z0-9_]{6,100}$", options: .regularExpression) != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var identityHint: String { subtitle + " · " + identifier.suffix(6) }
}

struct FeishuSendConfiguration: Codable, Equatable, Sendable {
    var enabled = true
    var cliPath = ""
    var accountOpenID = ""
    var appID = ""
    // Membership in this local list means the user explicitly enabled dropping to send.
    var destinations: [FeishuDestination] = []
    func validate() throws {
        guard destinations.count <= 200, destinations.allSatisfy(\.isValid), Set(destinations.map(\.id)).count == destinations.count else { throw RuleError.invalid("飞书授权会话包含无效或重复 ID，最多 200 个") }
        if !destinations.isEmpty {
            guard accountOpenID.hasPrefix("ou_"), !appID.isEmpty else { throw RuleError.invalid("授权会话必须绑定当前飞书账号与应用") }
        }
    }
}

struct FeishuAccount: Equatable, Sendable {
    var openID: String
    var name: String
    var appID: String
    var scopes: Set<String>
    var canSend: Bool { scopes.contains("im:message.send_as_user") }
}

struct ConversationHoverGate: Equatable {
    var iconVisible = false
    var listExpanded = false
    var listExpandedAt: TimeInterval?
    mutating func reset() { self = .init() }
    mutating func update(onTarget: Bool, inside: Bool, onEntryZone: Bool, time: TimeInterval) {
        guard onTarget, inside else { reset(); return }
        iconVisible = true
        if iconVisible && onEntryZone, !listExpanded { listExpanded = true; listExpandedAt = time }
    }
}

enum FeishuGridGeometry {
    static let padding: CGFloat = 16
    static let gap: CGFloat = 10
    static let cardHeight: CGFloat = 62
    static let gridTop: CGFloat = 168
    static func rows(_ count: Int) -> Int { (max(0, count) + 1) / 2 }
    static func visibleRows(_ count: Int, availableHeight: CGFloat = 800) -> Int {
        min(rows(count), max(1, min(6, Int((availableHeight - gridTop - padding) / (cardHeight + gap)))))
    }
    static func height(_ count: Int, visibleRows: Int) -> CGFloat {
        guard count > 0 else { return gridTop + 76 }
        return gridTop + CGFloat(visibleRows) * (cardHeight + gap) - gap + padding
    }
    static func index(at point: CGPoint, count: Int, firstRow: Int, visibleRows: Int) -> Int? {
        let width = (DropGeometry.bodySize.width - padding * 2 - gap) / 2
        let y = point.y - gridTop
        guard y >= 0, point.x >= padding else { return nil }
        let row = Int(y / (cardHeight + gap)), column = Int((point.x - padding) / (width + gap))
        guard row < visibleRows, column < 2, (point.x - padding).truncatingRemainder(dividingBy: width + gap) <= width, y.truncatingRemainder(dividingBy: cardHeight + gap) <= cardHeight else { return nil }
        let index = (firstRow + row) * 2 + column
        return index < count ? index : nil
    }
}

struct FeishuReceipt: Equatable, Sendable { var messageID: String }
struct FeishuTransfer: Equatable {
    enum Status { case receiving, sending, sent, failed, uncertain }
    var status: Status
    var recipient: String
    var detail: String
    var messageIDs: [String] = []
}
