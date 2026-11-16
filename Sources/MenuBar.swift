import AppKit
import Carbon.HIToolbox
import SwiftUI
import Observation

#if !SUPERINPUT_DROP_TEST
@main
struct SuperInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState!
    var menuBar: MenuBarController!
    var settings: SettingsController!
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        var override = ProcessInfo.processInfo.environment["SUPERINPUT_DATA_ROOT"]
        #if SUPERINPUT_UI_TEST
        override = FileManager.default.temporaryDirectory.appendingPathComponent("SuperInputDemo-Feishu-UI-Test").path
        #endif
        state = AppState(paths: override.map { AppPaths(root: URL(fileURLWithPath: $0)) } ?? .standard)
        #if SUPERINPUT_UI_TEST
        state.feishuTransport = UIOnlyFeishuTransport()
        state.feishuTestConfiguration = .init(enabled: true, cliPath: "", accountOpenID: "ou_ui_self", appID: "cli_ui_test", destinations: UIOnlyFeishuTransport.destinations)
        #endif
        settings = SettingsController(state: state)
        menuBar = MenuBarController(state: state)
        state.requestSettings = { [weak self] id in self?.settings.show(id) }
        state.onRulesChanged = { [weak self] in self?.menuBar.refresh() }
        state.onFeishuTransferChanged = { [weak self] in self?.menuBar.showDelivery() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { delegate.menuBar.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x5355494E, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { state.message = "快捷键被占用；仍可从菜单栏打开" }
        #if SUPERINPUT_UI_TEST
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.menuBar.showDragCheck()
        }
        #endif
        if !UserDefaults.standard.bool(forKey: "didShowFeishuOnlyTutorial") {
            UserDefaults.standard.set(true, forKey: "didShowFeishuOnlyTutorial")
            settings.show("tutorial")
        }
        #if SUPERINPUT_CONNECTION_CHECK
        settings.show("feishu")
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.show(state?.selectedTarget)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        state.persist()
        menuBar.shutdown()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

@MainActor
enum TargetIcon {
    static func image(_ rule: AppRule) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier) { return NSWorkspace.shared.icon(forFile: url.path) }
        let defaults = ["feishu": "com.bytedance.macos.feishu"]
        if let id = defaults[rule.id], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: rule.symbol, accessibilityDescription: rule.name) ?? NSImage(systemSymbolName: "app", accessibilityDescription: rule.name)!
    }
}

@MainActor
final class DropIntake {
    static var types: [NSPasteboard.PasteboardType] { [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } }
    static func accepts(_ sender: NSDraggingInfo) -> Bool { sender.draggingPasteboard.availableType(from: types) != nil }
    static func receiveDirect(_ sender: NSDraggingInfo, state: AppState, destination: FeishuDestination) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            Task { await state.sendFeishu(urls, to: destination) }; return true
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperInput-Incoming-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return false }
        if let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let expected = receivers.reduce(0) { $0 + $1.fileNames.count }
            guard expected > 0 else { try? FileManager.default.removeItem(at: folder); return false }
            let batch = PromiseBatch(expected: expected) { urls, errors in
                Task { @MainActor in
                    defer { try? FileManager.default.removeItem(at: folder) }
                    if errors.isEmpty { await state.sendFeishu(urls, to: destination) }
                    else { state.feishuTransfer = .init(status: .failed, recipient: destination.name, detail: "部分临时文件接收失败，本批次未发送"); state.onFeishuTransferChanged?() }
                }
            }
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            for receiver in receivers { receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in batch.received(url, error) } }
            return true
        }
        var png = board.data(forType: .png)
        if png == nil, let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) { png = rep.representation(using: .png, properties: [:]) }
        if let png {
            let file = folder.appendingPathComponent("截图.png")
            do { try png.write(to: file) } catch { try? FileManager.default.removeItem(at: folder); return false }
            Task { await state.sendFeishu([file], to: destination); try? FileManager.default.removeItem(at: folder) }; return true
        }
        try? FileManager.default.removeItem(at: folder); return false
    }
    static func receive(_ sender: NSDraggingInfo, state: AppState, target: String?) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            Task { await state.stage(urls, target: target, autoImport: false) }; return true
        }
        if let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let folder = state.paths.root.appendingPathComponent("Incoming-" + UUID().uuidString, isDirectory: true)
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            catch { state.message = error.localizedDescription; return false }
            let batch = PromiseBatch(expected: receivers.reduce(0) { $0 + $1.fileNames.count }) { urls, errors in
                Task { @MainActor in
                    await state.stage(urls, target: target, autoImport: false)
                    if !errors.isEmpty { state.message = "部分临时文件接收失败：" + errors.joined(separator: "；") }
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            for receiver in receivers { receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in batch.received(url, error) } }
            return true
        }
        if let png = board.data(forType: .png) { Task { await state.stageImage(png, target: target, autoImport: false) }; return true }
        if let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            Task { await state.stageImage(png, target: target, autoImport: false) }; return true
        }
        return false
    }
}

final class PromiseBatch {
    let lock = NSLock()
    var remaining: Int
    var urls: [URL] = [], errors: [String] = []
    var finish: ([URL], [String]) -> Void
    init(expected: Int, finish: @escaping ([URL], [String]) -> Void) { remaining = expected; self.finish = finish }
    func received(_ url: URL, _ error: Error?) {
        lock.lock()
        if let error { errors.append(error.localizedDescription) } else { urls.append(url) }
        remaining -= 1
        let done = remaining == 0, results = urls, failures = errors
        lock.unlock()
        if done { finish(results, failures) }
    }
}

final class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class DropExperience {
    var visible = false
    var expanded = false
    var pointer = CGPoint(x: 0.5, y: 0.5)
    var selected = 0
    var feishuHover = ConversationHoverGate()
    var deliveryTarget = "feishu"
    var contactIndex: Int?
    var firstRow = 0
    var visibleRows = 0
    var deliveryVisible = false
}

@MainActor
final class MenuBarController: NSObject {
    let state: AppState
    let experience = DropExperience()
    let statusItem: NSStatusItem
    let panel: InputPanel
    let receiver: InputPanel
    var statusView: StatusTargetsView!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var collapseWork: DispatchWorkItem?
    private var finishWork: DispatchWorkItem?
    private var deliveryWork: DispatchWorkItem?
    private var lastScrollTime: TimeInterval = 0
    private var dragActive = false
    private var dragSessionID = UUID()
    private var idlePasteboardCount: Int
    private var sensingFrame = CGRect.zero
    private var bodyFrame = CGRect.zero
    private var menuAnchor = CGRect.zero
    #if SUPERINPUT_UI_TEST
    private var uiCheckWindow: NSWindow?
    private var visualCheckPrepared = false
    #endif
    init(state: AppState) {
        self.state = state
        idlePasteboardCount = NSPasteboard(name: .drag).changeCount
        statusItem = NSStatusBar.system.statusItem(withLength: 88)
        panel = InputPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 380), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        receiver = InputPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        for p in [panel, receiver] {
            p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
            p.hidesOnDeactivate = false; p.isFloatingPanel = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isMovableByWindowBackground = false
        }
        receiver.ignoresMouseEvents = true
        receiver.contentView = NearDropView(controller: self)
        panel.contentView = DropPanelView(rootView: PanelContent(state: state, close: { [weak self] in self?.panel.orderOut(nil) }), state: state)
        refresh()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.observe(event) }
        var localMask = mask
        #if SUPERINPUT_UI_TEST
        localMask.insert(.keyDown)
        #endif
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: localMask) { [weak self] event in
            #if SUPERINPUT_UI_TEST
            if event.type == .keyDown, event.keyCode == UInt16(kVK_ANSI_P), event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] { self?.showVisualCheck(); return nil }
            #endif
            self?.observe(event); return event
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func shutdown() {
        timer?.invalidate(); collapseWork?.cancel(); finishWork?.cancel(); deliveryWork?.cancel()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        receiver.orderOut(nil); panel.orderOut(nil)
    }
    func refresh() {
        statusItem.length = max(28, CGFloat(state.ruleStore.rules.count - 1) * 27 + 34)
        statusView?.removeFromSuperview()
        statusView = StatusTargetsView(controller: self)
        if let button = statusItem.button {
            statusView.frame = button.bounds; statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
        }
        reposition()
    }
    private func reposition() {
        guard let button = statusItem.button, let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        menuAnchor = anchor
        experience.visibleRows = FeishuGridGeometry.visibleRows(state.feishuDestinations.count, availableHeight: screen.visibleFrame.height - 40)
        let bodyHeight = experience.feishuHover.listExpanded ? FeishuGridGeometry.height(state.feishuDestinations.count, visibleRows: experience.visibleRows) : DropGeometry.bodySize.height
        let next = DropGeometry.sensingFrame(anchor: anchor, visibleFrame: screen.visibleFrame, height: max(DropGeometry.sensingSize.height, bodyHeight + 40))
        bodyFrame = DropGeometry.bodyFrame(in: next, height: bodyHeight)
        if next != sensingFrame { sensingFrame = next; receiver.setFrame(next, display: false); trace("frame=\(next)") }
    }
    private func observe(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            idlePasteboardCount = NSPasteboard(name: .drag).changeCount
            if panel.isVisible && !panel.frame.contains(NSEvent.mouseLocation) { panel.orderOut(nil) }
        } else if event.type == .leftMouseUp, dragActive { scheduleFinish() }
        else if event.type == .leftMouseDragged { tick() }
    }
    private func tick() {
        reposition()
        let board = NSPasteboard(name: .drag)
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            idlePasteboardCount = board.changeCount
            if dragActive { scheduleFinish() }
            return
        }
        if !dragActive, board.changeCount != idlePasteboardCount, board.availableType(from: DropIntake.types) != nil { armDrag() }
        guard dragActive else { return }
        let point = NSEvent.mouseLocation
        if sensingFrame.contains(point) || menuAnchor.contains(point) { updateDrag(at: point) }
        else if experience.expanded { scheduleCollapse() }
    }
    private func armDrag() {
        dragSessionID = UUID()
        finishWork?.cancel(); finishWork = nil
        deliveryWork?.cancel(); experience.deliveryVisible = false
        #if SUPERINPUT_UI_TEST
        if !visualCheckPrepared { experience.feishuHover.reset(); experience.contactIndex = nil; experience.firstRow = 0 }
        visualCheckPrepared = false
        #else
        experience.feishuHover.reset(); experience.contactIndex = nil; experience.firstRow = 0
        #endif
        if let index = state.ruleStore.rules.firstIndex(where: { $0.id == state.selectedTarget }) { experience.selected = index }
        dragActive = true
        trace("armed")
        panel.orderOut(nil)
        receiver.ignoresMouseEvents = false
        // One continuous destination stays in place throughout the drag. Animated
        // content changes inside it, so expanding cannot lose the native session.
        receiver.orderFrontRegardless()
    }
    func updateDrag(at point: CGPoint) {
        guard !state.transferBusy else { return }
        if !dragActive { armDrag() }
        collapseWork?.cancel(); collapseWork = nil
        let count = state.ruleStore.rules.count
        // Always split the original 156-point header. Contact rows added below
        // it are destinations, not part of the application-switching surface.
        let header = DropGeometry.bodyFrame(in: sensingFrame)
        let listExpanded = experience.feishuHover.listExpanded
        guard let index = DropGeometry.targetIndex(at: point, header: header, count: count, previous: experience.selected, listExpanded: listExpanded) else { return }
        experience.selected = index
        if !state.isImporting { state.selectedTarget = state.ruleStore.rules[index].id }
        experience.pointer = DropGeometry.normalizedPointer(point, body: DropGeometry.bodyFrame(in: sensingFrame))
        let time = Date().timeIntervalSinceReferenceDate
        let onEntryZone = DropGeometry.isAppEntryZone(point, header: header)
        experience.feishuHover.update(onTarget: state.ruleStore.rules[index].id == "feishu", inside: sensingFrame.contains(point), onEntryZone: onEntryZone, time: time)
        reposition()
        if experience.feishuHover.listExpanded {
            reposition()
            let local = CGPoint(x: point.x - bodyFrame.minX, y: bodyFrame.maxY - point.y)
            let totalRows = FeishuGridGeometry.rows(state.feishuDestinations.count)
            if time - lastScrollTime > 0.35 {
                if local.y > bodyFrame.height - 16, experience.firstRow + experience.visibleRows < totalRows { experience.firstRow += 1; lastScrollTime = time }
                else if local.y >= FeishuGridGeometry.gridTop - 12, local.y < FeishuGridGeometry.gridTop, experience.firstRow > 0 { experience.firstRow -= 1; lastScrollTime = time }
            }
            experience.contactIndex = FeishuGridGeometry.index(at: local, count: state.feishuDestinations.count, firstRow: experience.firstRow, visibleRows: experience.visibleRows)
        } else { experience.contactIndex = nil }
        if !experience.visible {
            experience.visible = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.dragActive, self.sensingFrame.contains(NSEvent.mouseLocation) || self.menuAnchor.contains(NSEvent.mouseLocation) else { return }
                self.experience.expanded = true
                self.trace("expanded; target=\(self.state.selectedTarget)")
            }
        } else {
            if !experience.expanded { trace("expanded; target=\(state.selectedTarget)") }
            experience.expanded = true
        }
    }
    private func scheduleCollapse() {
        guard collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }
    private func collapse() {
        guard !experience.deliveryVisible else { return }
        experience.expanded = false; collapseWork = nil
        experience.feishuHover.reset(); experience.contactIndex = nil
        trace("collapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self, !self.experience.expanded else { return }
            self.experience.visible = false
            if !self.dragActive { self.receiver.orderOut(nil) }
        }
    }
    func finishDrag() {
        finishWork?.cancel(); finishWork = nil
        dragActive = false; receiver.ignoresMouseEvents = true
        collapseWork?.cancel(); collapseWork = nil; collapse()
    }
    private func scheduleFinish() {
        guard finishWork == nil else { return }
        // AppKit decides and delivers the drop on mouse-up. Keep the destination
        // receptive until that callback has had a chance to finish.
        let work = DispatchWorkItem { [weak self] in self?.finishDrag() }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    func accept(_ sender: NSDraggingInfo) -> Bool {
        guard DropIntake.accepts(sender) else { return false }
        guard !state.isStaging, !state.transferBusy else { return false }
        if state.selectedTarget == "feishu" {
            guard let window = receiver.contentView?.window, experience.feishuHover.listExpanded,
                  let openedAt = experience.feishuHover.listExpandedAt, Date().timeIntervalSinceReferenceDate - openedAt >= 0.27 else { finishDrag(); return false }
            let point = window.convertPoint(toScreen: sender.draggingLocation)
            let local = CGPoint(x: point.x - bodyFrame.minX, y: bodyFrame.maxY - point.y)
            guard let index = FeishuGridGeometry.index(at: local, count: state.feishuDestinations.count, firstRow: experience.firstRow, visibleRows: experience.visibleRows) else { finishDrag(); return false }
            let destination = state.feishuDestinations[index]
            let result = DropIntake.receiveDirect(sender, state: state, destination: destination)
            trace("direct-drop=\(result); contact=\(index)")
            if result { state.feishuTransfer = .init(status: .receiving, recipient: destination.name, detail: "正在接收文件…"); showDelivery() }
            finishDrag(); return result
        }
        let result = DropIntake.receive(sender, state: state, target: state.selectedTarget)
        trace("native-drop=\(result); target=\(state.selectedTarget)")
        finishDrag(); return result
    }
    func showDelivery() {
        guard let transfer = state.feishuTransfer else { return }
        deliveryWork?.cancel(); collapseWork?.cancel(); collapseWork = nil
        experience.feishuHover.reset(); experience.contactIndex = nil
        experience.deliveryTarget = "feishu"; experience.deliveryVisible = true; experience.visible = true; experience.expanded = true
        if let index = state.ruleStore.rules.firstIndex(where: { $0.id == "feishu" }) { experience.selected = index }
        reposition(); receiver.ignoresMouseEvents = true; receiver.orderFrontRegardless()
        if transfer.status != .sending && transfer.status != .receiving {
            let work = DispatchWorkItem { [weak self] in self?.experience.deliveryVisible = false; self?.collapse() }
            deliveryWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + (transfer.status == .sent ? 3.0 : 7.0), execute: work)
        }
    }
    private func trace(_ message: String) {
        #if SUPERINPUT_UI_TEST
        let url = state.paths.root.appendingPathComponent("drag-events.log")
        let data = Data(("\(Date().timeIntervalSince1970) \(message)\n").utf8)
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
        else if let file = try? FileHandle(forWritingTo: url) { _ = try? file.seekToEnd(); try? file.write(contentsOf: data); try? file.close() }
        #endif
    }
    #if SUPERINPUT_UI_TEST
    func showDragCheck() {
        reposition()
        let window = NSWindow(contentRect: CGRect(x: sensingFrame.minX, y: sensingFrame.minY - 176, width: 368, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "本地拖放检查 · 不导入下游"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DragCheckContent(state: state, experience: experience))
        uiCheckWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        trace("test-window=\(window.frame)")
    }
    private func showVisualCheck() {
        visualCheckPrepared = true
        experience.selected = state.ruleStore.rules.firstIndex(where: { $0.id == "feishu" }) ?? 0; state.selectedTarget = "feishu"; experience.pointer = CGPoint(x: 0.28, y: 0.65)
        experience.feishuHover.listExpandedAt = Date().timeIntervalSinceReferenceDate - 1
        experience.feishuHover.iconVisible = true; experience.feishuHover.listExpanded = true; experience.contactIndex = 1
        reposition()
        uiCheckWindow?.setContentSize(CGSize(width: 368, height: sensingFrame.height + 176))
        uiCheckWindow?.setFrameOrigin(CGPoint(x: sensingFrame.minX, y: sensingFrame.minY - 176))
        experience.visible = true; experience.expanded = true
        receiver.ignoresMouseEvents = true; receiver.orderFrontRegardless()
    }
    #endif
    func toggle() { if panel.isVisible { panel.orderOut(nil) } else { show(target: state.selectedTarget) } }
    func show(target: String) {
        finishDrag(); state.selectedTarget = target; reposition()
        panel.setFrameOrigin(CGPoint(x: bodyFrame.minX, y: sensingFrame.maxY - 380))
        panel.orderFrontRegardless()
    }
    func menu(event: NSEvent?) {
        let menu = NSMenu()
        for (title, action, key) in [("暂存附件", #selector(openShelf), ""), ("设置…", #selector(openSettings), ","), ("配置教程…", #selector(openTutorial), ""), ("退出 Super Input", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "⌃⌥ Space · 打开暂存区", action: nil, keyEquivalent: ""))
        if let event, let statusView { NSMenu.popUpContextMenu(menu, with: event, for: statusView) }
    }
    @objc func openShelf() { toggle() }
    @objc func openSettings() { finishDrag(); panel.orderOut(nil); state.requestSettings?(state.selectedTarget) }
    @objc func openTutorial() { finishDrag(); panel.orderOut(nil); state.requestSettings?("tutorial") }
    @objc func reload() { state.ruleStore.reload(); refresh(); state.message = "规则已重新加载" }
    @objc func quit() { NSApp.terminate(nil) }
}

#if SUPERINPUT_UI_TEST
struct DragCheckContent: View {
    @Bindable var state: AppState
    @Bindable var experience: DropExperience
    var body: some View {
        let previewHeight = experience.feishuHover.listExpanded ? max(224, FeishuGridGeometry.height(state.feishuDestinations.count, visibleRows: experience.visibleRows) + 40) : 224
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 8) {
                    Text("把下面的文件向上拖到这里").font(.system(size: 12))
                    Text("位置在菜单栏下方，不需要触碰屏幕顶边").font(.system(size: 10)).foregroundStyle(.secondary)
                }.opacity(experience.visible ? 0 : 1)
                DropPreviewContent(state: state, experience: experience)
            }.frame(maxWidth: .infinity).frame(height: previewHeight)
            UIDragFixture().frame(height: 100)
            Text(state.feishuTransfer.map { "本地模拟：\($0.recipient) · \($0.detail)" } ?? "拖入飞书会话可检查交互，不会实际发送")
                .font(.system(size: 10)).multilineTextAlignment(.center).padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 368, height: previewHeight + 176).background(Color(nsColor: .windowBackgroundColor))
    }
}
struct UIDragFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> UIDragFixtureView { UIDragFixtureView() }
    func updateNSView(_ view: UIDragFixtureView, context: Context) {}
}
final class UIDragFixtureView: NSView, NSDraggingSource {
    let file: URL
    override init(frame frameRect: NSRect) {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("SuperInputDemo-Feishu-UI-Test/Native-Drag-Fixture.png")
        super.init(frame: frameRect)
        let image = NSImage(size: NSSize(width: 120, height: 80))
        image.lockFocus(); NSColor.systemTeal.setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 120, height: 80), xRadius: 12, yRadius: 12).fill(); image.unlockFocus()
        if let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: file) }
        setAccessibilityElement(true); setAccessibilityLabel("拖放测试 PNG 文件")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 28, dy: 10), xRadius: 14, yRadius: 14).fill()
        let text = "拖动此文件 · PNG" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: NSWorkspace.shared.icon(forFile: file.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
#endif

struct AvatarStack: View {
    @Bindable var state: AppState
    @Bindable var experience: DropExperience
    var open: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let rules = state.ruleStore.rules
        let step: CGFloat = experience.expanded ? 27 : 14
        ZStack {
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                let selected = experience.expanded && experience.selected == index
                Button { open(rule.id) } label: {
                    Image(nsImage: TargetIcon.image(rule)).resizable().scaledToFill()
                        .frame(width: selected ? 23 : 22, height: selected ? 23 : 22)
                        .background(Color.white.opacity(0.12)).clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(selected ? 1 : 0), lineWidth: 1.35).padding(selected ? -1.35 : 0))
                        .padding(selected ? 1.5 : 0)
                }.buttonStyle(.plain)
                .offset(x: (CGFloat(index) - CGFloat(max(0, rules.count - 1)) / 2) * step)
                .zIndex(selected ? 100 : Double(rules.count - index))
                .help("\(rule.name) · \(rule.targetLabel)")
                .accessibilityLabel("\(rule.name) · \(rule.targetLabel)")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .linear(duration: 0.10) : .spring(response: 0.26, dampingFraction: 0.82), value: experience.expanded)
        .animation(reduceMotion ? .linear(duration: 0.10) : .spring(response: 0.16, dampingFraction: 0.88), value: experience.selected)
    }
}

@MainActor
final class StatusTargetsView: NSHostingView<AvatarStack> {
    weak var controller: MenuBarController?
    init(controller: MenuBarController) {
        self.controller = controller
        super.init(rootView: AvatarStack(state: controller.state, experience: controller.experience, open: { [weak controller] in controller?.show(target: $0) }))
        registerForDraggedTypes(DropIntake.types)
    }
    required init(rootView: AvatarStack) { fatalError() }
    required init?(coder: NSCoder) { fatalError() }
    override func rightMouseDown(with event: NSEvent) { controller?.menu(event: event) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard DropIntake.accepts(sender), let controller, let window else { return [] }
        controller.updateDrag(at: window.convertPoint(toScreen: sender.draggingLocation)); return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.accept(sender) ?? false }
}

@MainActor
final class NearDropView: NSHostingView<DropPreviewContent> {
    weak var controller: MenuBarController?
    init(controller: MenuBarController) {
        self.controller = controller
        super.init(rootView: DropPreviewContent(state: controller.state, experience: controller.experience))
        registerForDraggedTypes(DropIntake.types)
    }
    required init(rootView: DropPreviewContent) { fatalError() }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard DropIntake.accepts(sender), let controller, let window else { return [] }
        controller.updateDrag(at: window.convertPoint(toScreen: sender.draggingLocation)); return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.accept(sender) ?? false }
}

struct ReactiveDotField: View, Animatable {
    var pointer: CGPoint
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pointer.x, pointer.y) }
        set { pointer = CGPoint(x: newValue.first, y: newValue.second) }
    }
    var body: some View {
        Canvas { context, size in
            let cursor = CGPoint(x: pointer.x * size.width, y: pointer.y * size.height)
            let spacing: CGFloat = 9.6
            for y in stride(from: CGFloat(7), through: size.height, by: spacing) {
                for x in stride(from: CGFloat(7), through: size.width, by: spacing) {
                    let distanceSquared = pow(x - cursor.x, 2) + pow(y - cursor.y, 2)
                    let influence = exp(-distanceSquared / (2 * 52 * 52))
                    let radius = 0.38 + 0.94 * influence
                    let edge = min(1, min(x, size.width - x, y, size.height - y) / 20)
                    let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity((0.08 + influence * 0.40) * edge)))
                }
            }
        }.allowsHitTesting(false)
    }
}

struct DropPreviewContent: View {
    @Bindable var state: AppState
    @Bindable var experience: DropExperience
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isFeishu: Bool { state.ruleStore.rules.indices.contains(experience.selected) && state.ruleStore.rules[experience.selected].id == "feishu" }
    var label: String {
        if isFeishu {
            if experience.feishuHover.listExpanded { return "选择会话 · 松手发送" }
            return experience.feishuHover.iconVisible ? "拖到上半区选择会话" : "Drop to 飞书"
        }
        guard state.ruleStore.rules.indices.contains(experience.selected) else { return "Drop here" }
        let r = state.ruleStore.rules[experience.selected]
        return "Drop to \(r.name)"
    }
    var iconRule: AppRule? {
        let visible = isFeishu && experience.feishuHover.iconVisible
        guard visible else { return nil }
        return state.ruleStore.rules.first { $0.id == "feishu" }
    }
    var receiverHeader: some View {
        ZStack(alignment: .top) {
            ReactiveDotField(pointer: experience.pointer)
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.9), value: experience.pointer)
            if experience.deliveryVisible, experience.deliveryTarget == "feishu", let transfer = state.feishuTransfer {
                TransferStatusContent(busy: transfer.status == .receiving || transfer.status == .sending, success: transfer.status == .sent, name: transfer.recipient, detail: transfer.detail)
            } else {
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let rule = iconRule {
                    Image(nsImage: TargetIcon.image(rule)).resizable().scaledToFill().frame(width: 34, height: 34)
                        .clipShape(Circle()).overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.2))
                        .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
                        .position(x: 160, y: 26).transition(.scale(scale: 0.65).combined(with: .opacity))
                }
                Text("拖到上半区展开会话，松手到卡片发送").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).position(x: 160, y: 132)
            }
        }.frame(width: 320, height: 156)
    }
    var showContacts: Bool { isFeishu && experience.feishuHover.listExpanded }
    var receiverHeight: CGFloat {
        showContacts ? FeishuGridGeometry.height(state.feishuDestinations.count, visibleRows: experience.visibleRows) : DropGeometry.bodySize.height
    }
    var collapsedOffset: CGFloat {
        CGFloat(experience.selected - max(0, state.ruleStore.rules.count - 1) / 2) * 14
    }
    @ViewBuilder var contactList: some View {
        if state.feishuDestinations.isEmpty {
            VStack(spacing: 5) {
                Text("还没有授权会话").font(.system(size: 12, weight: .medium))
                Text("在设置 → 飞书中勾选可直接发送的会话").font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(height: 76).frame(maxWidth: .infinity).padding(.top, 12)
        } else {
            FeishuContactGrid(destinations: state.feishuDestinations, experience: experience)
                .padding(.top, 12).padding(.horizontal, 16).padding(.bottom, 16)
        }
    }
    var receiverContents: some View {
        VStack(spacing: 0) {
            receiverHeader.opacity(experience.expanded ? 1 : 0)
            if showContacts { contactList }
        }
    }
    var receiverPanel: some View {
        let expanded = experience.expanded
        let shape = RoundedRectangle(cornerRadius: expanded ? 36 : 10, style: .continuous)
        return receiverContents
            .frame(width: expanded ? 320 : 24, height: expanded ? receiverHeight : 20, alignment: .top)
            .background(.ultraThinMaterial).background(Color.black.opacity(0.16))
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.65))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
            .offset(x: expanded ? 0 : collapsedOffset)
            .animation(reduceMotion ? .linear(duration: 0.10) : .spring(response: 0.27, dampingFraction: 0.84), value: expanded)
            .animation(reduceMotion ? .linear(duration: 0.10) : .spring(response: 0.27, dampingFraction: 0.86), value: showContacts)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: experience.feishuHover.iconVisible)
    }
    var body: some View {
        ZStack {
            if experience.visible { receiverPanel }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.001)).environment(\.colorScheme, .dark)
    }
}

struct TransferStatusContent: View {
    var busy: Bool
    var success: Bool
    var name: String
    var detail: String
    var body: some View {
        VStack(spacing: 7) {
            if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle").font(.system(size: 19)).foregroundStyle(success ? Color.green : Color.orange) }
            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(3).multilineTextAlignment(.center)
        }.frame(width: 278, height: 156)
    }
}

struct FeishuContactGrid: View {
    var destinations: [FeishuDestination]
    @Bindable var experience: DropExperience
    var body: some View {
        let start = experience.firstRow * 2
        let end = min(destinations.count, start + experience.visibleRows * 2)
        LazyVGrid(columns: [GridItem(.fixed(139)), GridItem(.fixed(139))], spacing: 10) {
            ForEach(Array(destinations.indices.dropFirst(start).prefix(max(0, end - start))), id: \.self) { index in
                let contact = destinations[index]
                let selected = experience.contactIndex == index
                HStack(spacing: 8) {
                    ConversationAvatar(destination: contact).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(contact.identityHint).font(.system(size: 8)).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).frame(height: 62)
                .background(Color.white.opacity(selected ? 0.16 : 0.045), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.white.opacity(selected ? 0.75 : 0.06), lineWidth: selected ? 1.1 : 0.5))
                .animation(.easeOut(duration: 0.12), value: selected)
                .accessibilityLabel("\(contact.name)，松手直接发送")
            }
        }
    }
}
struct ConversationAvatar: View {
    var destination: FeishuDestination
    var body: some View {
        ZStack {
            Circle().fill(Color.blue.opacity(0.18))
            Text(String(destination.name.prefix(1))).font(.system(size: 12, weight: .semibold))
            if let url = URL(string: destination.avatarURL), !destination.avatarURL.isEmpty {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }.clipShape(Circle())
    }
}

@MainActor
final class DropPanelView: NSHostingView<PanelContent> {
    let state: AppState
    init(rootView: PanelContent, state: AppState) { self.state = state; super.init(rootView: rootView); registerForDraggedTypes(DropIntake.types) }
    required init(rootView: PanelContent) { fatalError() }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { DropIntake.accepts(sender) ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { DropIntake.accepts(sender) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { DropIntake.receive(sender, state: state, target: state.selectedTarget) }
}

struct PanelContent: View {
    @Bindable var state: AppState
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Super Input").font(.system(size: 15, weight: .semibold))
                    Text("附件暂存区").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.requestSettings?(state.selectedTarget) } label: { Image(systemName: "gearshape") }.help("设置")
                Button(action: close) { Image(systemName: "xmark") }.help("收起，文件会保留")
            }.buttonStyle(.borderless).padding(16)
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) {
                ForEach(state.ruleStore.rules) { rule in
                    Button { state.selectedTarget = rule.id } label: {
                        HStack(spacing: 5) { Image(nsImage: TargetIcon.image(rule)).resizable().frame(width: 19, height: 19); Text(rule.name).font(.caption) }
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .background(state.selectedTarget == rule.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).disabled(state.isImporting)
                }
            }}.padding(.horizontal, 16)
            HStack { Image(systemName: "person.crop.circle"); Text(state.selectedRule?.targetLabel ?? "目标不可用"); Spacer(); Text("未发送").foregroundStyle(.secondary) }
                .font(.caption).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if state.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text("把文件拖到这里").font(.headline)
                    Text("图片、截图、PDF、文本与其他文件\n暂存后，把缩略图拖到飞书会话卡片发送")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("选择文件…") { selectFiles() }.padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(state.items) { item in
                            HStack(alignment: .top, spacing: 10) {
                                FileThumbnail(url: state.fileURL(item)).frame(width: 38, height: 42).draggable(state.fileURL(item))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(item.status.label).font(.caption).foregroundStyle(item.status == .uncertain ? Color.orange : Color.secondary)
                                    if !item.detail.isEmpty { Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                }
                                Spacer(minLength: 0)
                                Button { state.remove(item.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).disabled(state.isImporting)
                            }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(16)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    if state.isStaging || state.isImporting { ProgressView().controlSize(.small) }
                    Text(state.message).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("清空") { state.clear() }.disabled(state.items.isEmpty || state.isImporting)
                    Spacer()
                    Button("添加文件…") { selectFiles() }
                    Button("飞书设置") { close(); state.requestSettings?("feishu") }.buttonStyle(.borderedProminent)
                }.controlSize(.small)
            }.padding(16)
        }.frame(width: 320, height: 380).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
    func selectFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.title = "添加到暂存区"
        panel.begin { response in if response == .OK { Task { await state.stage(panel.urls, target: state.selectedTarget, autoImport: false) } } }
    }
}

struct FileThumbnail: View {
    var url: URL
    @State private var image: NSImage?
    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            .task(id: url) {
                if ["png", "jpg", "jpeg", "heic", "webp", "tiff"].contains(url.pathExtension.lowercased()) { image = NSImage(contentsOf: url) }
            }
    }
}

#if SUPERINPUT_UI_TEST
actor UIOnlyFeishuTransport: FeishuTransporting {
    static let destinations = ["演示会话一", "演示会话二", "演示会话三", "演示会话四", "演示会话五"].enumerated().map { FeishuDestination(identifier: "oc_ui_test_\($0.offset)", kind: .chat, name: $0.element, subtitle: "演示 · 不实际发送") }
    func account(cliPath: String) async throws -> FeishuAccount { .init(openID: "ou_ui_self", name: "本地界面测试", appID: "cli_ui_test", scopes: ["im:message.send_as_user"]) }
    func conversations(cliPath: String, query: String?) async throws -> [FeishuDestination] { Self.destinations }
    func send(file: URL, destination: FeishuDestination, key: String, cliPath: String) async throws -> FeishuReceipt { .init(messageID: "om_ui_only_" + key) }
}
#endif
