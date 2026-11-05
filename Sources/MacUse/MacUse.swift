import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import Darwin

struct CUError: Error { let code: String; let message: String }
func fail(_ code: String, _ message: String) -> CUError { CUError(code: code, message: message) }
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
    guard let value = attribute(element, key) else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}
func elementRect(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
/// AX and ScreenCaptureKit can disagree by a point; avoid false `window_changed` on subpixel drift.
func rectsMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
}
func backingScale(for globalFrame: CGRect) -> CGFloat {
    for screen in NSScreen.screens where screen.frame.intersects(globalFrame) {
        return max(1, screen.backingScaleFactor)
    }
    return 2
}
func axIdentity(_ element: AXUIElement) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(element).toOpaque()
}
/// Resolve to a real directory owned by the current user, mode 0700, with no symlink at the final path.
func validateSocketDirectory(_ path: String) -> Bool {
    var st = stat()
    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
    guard st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return false }
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard path.withCString({ realpath($0, &buffer) }) != nil else { return false }
    let resolved = String(cString: buffer)
    guard lstat(resolved, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
    return st.st_uid == getuid() && st.st_mode & 0o077 == 0
}

/// macOS 15+ (Sequoia) warns when apps enumerate `SCShareableContent` without the system picker.
/// Register capture targets once via `SCContentSharingPicker`, then reuse the returned filters.
@MainActor
final class CaptureSelection: NSObject, SCContentSharingPickerObserver {
    private var filters: [String: SCContentFilter] = [:]
    private var pending: CheckedContinuation<Void, Error>?
    private var pendingApp: String?
    let allowedApps: Set<String>

    init(allowedApps: Set<String>) {
        self.allowedApps = allowedApps
        super.init()
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleApplication]
        config.allowsChangingSelectedContent = true
        picker.defaultConfiguration = config
    }

    func isRegistered(app: String) -> Bool { filters[app] != nil }
    func registeredApps() -> [String] { allowedApps.filter { filters[$0] != nil }.sorted() }

    func register(app: String) async throws {
        guard allowedApps.contains(app) else { throw fail("app_not_allowed", "Bundle \(app) is not in the service allowlist.") }
        if filters[app] != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending = continuation
            pendingApp = app
            SCContentSharingPicker.shared.present(using: .window)
        }
    }

    func ensureFilter(for app: String) async throws -> SCContentFilter {
        if let filter = filters[app] { return filter }
        try await register(app: app)
        guard let filter = filters[app] else {
            throw fail("capture_picker_required", "Choose \(app) in the system capture picker (see README).")
        }
        return filter
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            if let app = pendingApp { filters[app] = filter }
            pending?.resume()
            pending = nil
            pendingApp = nil
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            pending?.resume(throwing: fail("capture_picker_cancelled", "Screen capture picker was cancelled; no filter was saved."))
            pending = nil
            pendingApp = nil
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            pending?.resume(throwing: fail("capture_picker_failed", error.localizedDescription))
            pending = nil
            pendingApp = nil
        }
    }
}

struct Snapshot {
    let id: String
    let pid: pid_t
    let app: String
    let window: AXUIElement
    let rect: CGRect
    let nodes: [Int: AXUIElement]
    let created: Date
    var screenshotSize: CGSize?
    /// ScreenCaptureKit window frame used for the latest screenshot; preferred for coordinate clicks.
    var captureFrame: CGRect?
}

@MainActor final class Engine {
    let allowedApps: Set<String>
    var snapshots: [String: Snapshot] = [:]
    private let captureSelection: CaptureSelection?

    init(allowedApps: Set<String>) {
        self.allowedApps = allowedApps
        if #available(macOS 15.0, *) {
            self.captureSelection = CaptureSelection(allowedApps: allowedApps)
        } else {
            self.captureSelection = nil
        }
    }

    func permissions(prompt: Bool = false) -> [String: Any] {
        let trusted = prompt ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) : AXIsProcessTrusted()
        let screen: Bool
        if #available(macOS 15.0, *) {
            // Broad CGRequestScreenCaptureAccess() triggers Sequoia's bypass warning; use the system picker instead.
            screen = CGPreflightScreenCaptureAccess()
        } else {
            screen = prompt ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()
        }
        var result: [String: Any] = ["accessibility": trusted, "screen_recording": screen]
        if #available(macOS 15.0, *), let captureSelection, !allowedApps.isEmpty {
            result["capture_registered_apps"] = captureSelection.registeredApps()
            result["capture_picker_required_apps"] = allowedApps.filter { !captureSelection.isRegistered(app: $0) }.sorted()
        }
        return result
    }
    func app(_ name: String) async throws -> NSRunningApplication {
        guard allowedApps.contains(name) else { throw fail("app_not_allowed", "Start the service with --allow-app \(name) to allow this bundle identifier.") }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: name).first { return running }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) else { throw fail("app_not_found", "Application not installed: \(name)") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
    func requireAX() throws {
        guard AXIsProcessTrusted() else { throw fail("permission_required", "Allow this binary (or its launching terminal) in System Settings > Privacy & Security > Accessibility, then retry.") }
    }
    func window(_ running: NSRunningApplication) throws -> AXUIElement {
        let root = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        if let focused = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() { return focused as! AXUIElement }
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard windows.count == 1 else { throw fail("window_unavailable", windows.isEmpty ? "No accessible window; open an application window and retry." : "Multiple windows and no focused window; focus the intended window and retry.") }
        return windows[0]
    }
    func state(_ args: [String: Any], session: String) async throws -> [String: Any] {
        try requireAX()
        let name = try required(args, "app")
        let running = try await app(name)
        let selected = try window(running)
        guard let rect = elementRect(selected), rect.width > 0, rect.height > 0 else { throw fail("window_unavailable", "Window geometry is unavailable.") }
        var nodes: [Int: AXUIElement] = [:], lines: [String] = []
        var truncated = false
        var visited = Set<UnsafeMutableRawPointer>()
        func walk(_ item: AXUIElement, depth: Int) {
            guard nodes.count < 1200, depth <= 30 else { truncated = true; return }
            let identity = axIdentity(item)
            guard visited.insert(identity).inserted else { return }
            let index = nodes.count
            nodes[index] = item
            let fields = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { stringAttribute(item, $0) }.filter { !$0.isEmpty }.map { String($0.prefix(1000)) }
            let role = stringAttribute(item, kAXRoleAttribute) ?? "AXUnknown"
            var actions: CFArray?
            AXUIElementCopyActionNames(item, &actions)
            let actionNames = (actions as? [String] ?? []).joined(separator: ",")
            lines.append(String(repeating: "  ", count: depth) + "\(index) \(role) \(fields.joined(separator: " | "))" + (actionNames.isEmpty ? "" : " [actions: \(actionNames)]"))
            for child in attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(selected, depth: 0)
        let id = UUID().uuidString
        if snapshots.count >= 128, snapshots[session] == nil { throw fail("capacity", "Too many sessions; call end_session for unused sessions.") }
        snapshots[session] = Snapshot(id: id, pid: running.processIdentifier, app: name, window: selected, rect: rect, nodes: nodes, created: Date(), screenshotSize: nil, captureFrame: nil)
        return ["app": name, "pid": running.processIdentifier, "snapshot_id": id, "state": lines.joined(separator: "\n"), "truncated": truncated, "coordinates": "Screenshot pixels relative to the selected window; capture a screenshot before coordinate actions."]
    }
    func snapshot(_ args: [String: Any], session: String) throws -> Snapshot {
        guard let snapshot = snapshots[session] else { throw fail("snapshot_required", "Call get_app_state first in this session.") }
        guard args["snapshot_id"] as? String == snapshot.id, args["app"] as? String == snapshot.app else { throw fail("stale_snapshot", "Use the app and snapshot_id from the latest get_app_state.") }
        guard Date().timeIntervalSince(snapshot.created) < 120 else { snapshots.removeValue(forKey: session); throw fail("stale_snapshot", "Snapshot expired; call get_app_state again.") }
        guard let running = NSRunningApplication(processIdentifier: snapshot.pid), !running.isTerminated, running.bundleIdentifier == snapshot.app else { snapshots.removeValue(forKey: session); throw fail("target_exited", "Target application exited; select it again.") }
        let current = try window(running)
        guard CFEqual(current, snapshot.window), let currentRect = elementRect(current), rectsMatch(currentRect, snapshot.rect) else {
            snapshots.removeValue(forKey: session); throw fail("window_changed", "Selected window or geometry changed; call get_app_state again.")
        }
        return snapshot
    }
    func screenshot(_ args: [String: Any], session: String) async throws -> [String: Any] {
        let selected = try snapshot(args, session: session)
        if #available(macOS 15.0, *), let captureSelection {
            return try await screenshotWithPicker(selected: selected, args: args, session: session, captureSelection: captureSelection)
        }
        return try await screenshotWithShareableContent(selected: selected, args: args, session: session)
    }

    func screenshotWithPicker(selected: Snapshot, args: [String: Any], session: String, captureSelection: CaptureSelection) async throws -> [String: Any] {
        let filter = try await captureSelection.ensureFilter(for: selected.app)
        let scale = backingScale(for: selected.rect)
        let config = SCStreamConfiguration()
        config.width = Int((selected.rect.width * scale).rounded(.up))
        config.height = Int((selected.rect.height * scale).rounded(.up))
        guard config.width <= 8192, config.height <= 8192 else { throw fail("capture_too_large", "Window exceeds the 8192-pixel capture limit.") }
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        _ = try snapshot(args, session: session)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw fail("capture_failed", "PNG encoding failed.") }
        guard data.count <= 16 * 1024 * 1024 else { throw fail("capture_too_large", "Encoded screenshot exceeds 16 MiB.") }
        snapshots[session]?.screenshotSize = CGSize(width: image.width, height: image.height)
        snapshots[session]?.captureFrame = selected.rect
        return ["mimeType": "image/png", "data": data.base64EncodedString(), "width": image.width, "height": image.height, "snapshot_id": selected.id]
    }

    func screenshotWithShareableContent(selected: Snapshot, args: [String: Any], session: String) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { throw fail("permission_required", "Allow Screen & System Audio Recording for this binary or its launching terminal, then retry.") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let title = stringAttribute(selected.window, kAXTitleAttribute)
        let candidates = content.windows.filter { $0.owningApplication?.processID == selected.pid && abs($0.frame.minX - selected.rect.minX) < 2 && abs($0.frame.minY - selected.rect.minY) < 2 && abs($0.frame.width - selected.rect.width) < 2 && abs($0.frame.height - selected.rect.height) < 2 }
        let matching = candidates.count == 1 ? candidates : candidates.filter { $0.title == title }
        guard matching.count == 1, let target = matching.first else { throw fail("window_ambiguous", "Cannot uniquely match the AX window to a capturable window.") }
        let config = SCStreamConfiguration()
        let scale = backingScale(for: target.frame)
        config.width = Int((target.frame.width * scale).rounded(.up))
        config.height = Int((target.frame.height * scale).rounded(.up))
        guard config.width <= 8192, config.height <= 8192 else { throw fail("capture_too_large", "Window exceeds the 8192-pixel capture limit.") }
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        // Validate again after the asynchronous capture before retaining coordinate mapping.
        _ = try snapshot(args, session: session)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw fail("capture_failed", "PNG encoding failed.") }
        guard data.count <= 16 * 1024 * 1024 else { throw fail("capture_too_large", "Encoded screenshot exceeds 16 MiB.") }
        snapshots[session]?.screenshotSize = CGSize(width: image.width, height: image.height)
        snapshots[session]?.captureFrame = target.frame
        return ["mimeType": "image/png", "data": data.base64EncodedString(), "width": image.width, "height": image.height, "snapshot_id": selected.id]
    }
    func focus(_ selected: Snapshot) async throws {
        guard let running = NSRunningApplication(processIdentifier: selected.pid) else { throw fail("target_exited", "App exited.") }
        running.activate(options: [])
        AXUIElementPerformAction(selected.window, kAXRaiseAction as CFString)
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == selected.pid { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw fail("focus_failed", "The selected application did not become frontmost; no input was sent.")
    }
    func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw fail("input_failed", "Cannot create keyboard events.") }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    func input(_ name: String, _ args: [String: Any], session: String) async throws -> [String: Any] {
        try requireAX()
        let selected = try snapshot(args, session: session)
        // Input can change focus and UI across sessions; invalidate all retained snapshots before mutation.
        snapshots.removeAll()
        switch name {
        case "set_value":
            guard let index = args["element_index"] as? Int, let element = selected.nodes[index] else { throw fail("invalid_element", "Element index is not in this snapshot.") }
            let value = try required(args, "value", allowEmpty: true)
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { throw fail("unsupported_action", "Element value is not settable.") }
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else { throw fail("input_failed", "AX set_value failed.") }
        case "click":
            if let index = args["element_index"] as? Int {
                guard let element = selected.nodes[index] else { throw fail("invalid_element", "Element index is not in this snapshot.") }
                guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw fail("unsupported_action", "AXPress failed; capture a screenshot and use coordinates if appropriate.") }
            } else {
                guard let size = selected.screenshotSize, let x = args["x"] as? Double, let y = args["y"] as? Double, x.isFinite, y.isFinite, x >= 0, y >= 0, x < size.width, y < size.height else { throw fail("invalid_coordinates", "Capture a screenshot and provide x/y within its pixel bounds.") }
                try await focus(selected)
                let frame = selected.captureFrame ?? selected.rect
                let point = CGPoint(x: frame.minX + x * frame.width / size.width, y: frame.minY + y * frame.height / size.height)
                guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left), let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw fail("input_failed", "Cannot create mouse events.") }
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            }
        case "type_text":
            let text = try required(args, "text", allowEmpty: true)
            guard text.utf16.count <= 16000 else { throw fail("text_too_large", "Text input is limited to 16000 UTF-16 units per call.") }
            try await focus(selected)
            // Native controls such as Calculator consume one character per key event.
            for character in text {
                let units = Array(String(character).utf16)
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw fail("input_failed", "Cannot create Unicode input.") }
                units.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
        case "press_key":
            let value = try required(args, "key").lowercased()
            let parts = value.split(separator: "+").map(String.init)
            let codes: [String: CGKeyCode] = ["return":36, "enter":36, "tab":48, "space":49, "escape":53, "backspace":51, "delete":117, "left":123, "right":124, "down":125, "up":126, "a":0, "c":8, "v":9, "x":7, "z":6]
            guard let last = parts.last, let code = codes[last] else { throw fail("unsupported_key", "Supported keys: Return, Tab, Space, Escape, Backspace, Delete, arrows, a/c/v/x/z; modifiers: super, cmd, shift, alt, ctrl.") }
            var flags: CGEventFlags = []
            for part in parts.dropLast() {
                switch part { case "super", "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "alt", "option": flags.insert(.maskAlternate); case "ctrl", "control": flags.insert(.maskControl); default: throw fail("unsupported_key", "Unknown modifier: \(part)") }
            }
            try await focus(selected); try key(code, flags: flags)
        default: throw fail("unknown_tool", "Unknown mutation tool.")
        }
        // Allow native event delivery before taking the next observation.
        try await Task.sleep(nanoseconds: 120_000_000)
        return try await state(["app": selected.app], session: session)
    }
    func required(_ args: [String: Any], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = args[key] as? String, allowEmpty || !value.isEmpty else { throw fail("invalid_arguments", "Required string: \(key)") }
        return value
    }
    func execute(_ name: String, _ args: [String: Any], session: String) async throws -> [String: Any] {
        switch name {
        case "check_permissions": return permissions()
        case "list_apps": return ["apps": NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { ["app": $0.bundleIdentifier ?? "", "name": $0.localizedName ?? "", "pid": $0.processIdentifier, "allowed": allowedApps.contains($0.bundleIdentifier ?? "")] as [String: Any] }]
        case "get_app_state": return try await state(args, session: session)
        case "get_screenshot": return try await screenshot(args, session: session)
        case "click", "set_value", "type_text", "press_key": return try await input(name, args, session: session)
        case "end_session": snapshots.removeValue(forKey: session); return ["ended": true]
        case "register_capture":
            if #available(macOS 15.0, *), let captureSelection {
                let app = try required(args, "app")
                try await captureSelection.register(app: app)
                return ["registered": true, "app": app]
            }
            return ["registered": true, "note": "Not required before macOS 15."]
        default: throw fail("unknown_tool", "Unknown tool: \(name)")
        }
    }
    // One owner serializes whole operations, including asynchronous screenshot/focus waits.
    var busy = false
    func handle(_ request: [String: Any]) async -> [String: Any] {
        let id = request["id"] ?? NSNull()
        func response(_ result: [String: Any]) -> [String: Any] { ["jsonrpc":"2.0", "id":id, "result":result] }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String, request["id"] != nil else { return ["jsonrpc":"2.0", "id":id, "error":["code":-32600,"message":"Expected JSON-RPC 2.0 request with id."]] }
        if method == "ping" { return response(["serverApiVersion":"MacUse-1", "architecture":"arm64"]) }
        guard method == "tools/call", let params = request["params"] as? [String: Any], let name = params["name"] as? String, let session = params["session_id"] as? String, !session.isEmpty, session.utf8.count <= 128 else { return ["jsonrpc":"2.0", "id":id, "error":["code":-32602,"message":"Use tools/call with name, arguments and session_id (1..128 UTF-8 bytes)."]] }
        guard !busy else { return response(["isError":true,"code":"busy","message":"Another operation is in progress; retry after it completes."]) }
        busy = true
        defer { busy = false }
        do { return response(try await execute(name, params["arguments"] as? [String: Any] ?? [:], session: session)) }
        catch let error as CUError { return response(["isError":true,"code":error.code,"message":error.message]) }
        catch { return response(["isError":true,"code":"native_error","message":error.localizedDescription]) }
    }
}

// Length-prefixed JSON-RPC over an owner-only Unix socket; no TCP listener.
// Independent connections share the same long-lived Engine, with session-scoped AX snapshots.
func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var data = Data(count: count)
    var offset = 0
    let success = data.withUnsafeMutableBytes { raw -> Bool in
        while offset < count {
            let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
    return success ? data : nil
}
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < data.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
func serveConnection(_ fd: Int32, engine: Engine) async {
    defer { Darwin.close(fd) }
    var noPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
    while let header = readExactly(fd, 4) {
        let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        guard length > 0, length <= 1024 * 1024, let body = readExactly(fd, Int(length)), let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return }
        let response = await engine.handle(request)
        guard let data = try? JSONSerialization.data(withJSONObject: response), data.count <= 24 * 1024 * 1024 else { return }
        var little = UInt32(data.count).littleEndian
        let frame = withUnsafeBytes(of: &little) { Data($0) } + data
        guard writeAll(fd, frame) else { return }
    }
}

func rpcTool(socket path: String, name: String, arguments: [String: Any], session: String = "macuse-setup") throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw fail("socket_failed", "Cannot open control socket.") }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in path.utf8CString.withUnsafeBytes { raw.copyBytes(from: $0) } }
    guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else {
        throw fail("socket_connect_failed", "Cannot connect to \(path). Is MacUse Helper running?")
    }
    let id = UUID().uuidString
    let body = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":id, "method":"tools/call", "params":["session_id":session, "name":name, "arguments":arguments]])
    var size = UInt32(body.count).littleEndian
    let frame = withUnsafeBytes(of: &size) { Data($0) } + body
    try frame.withUnsafeBytes { raw in
        var offset = 0
        while offset < frame.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), frame.count - offset)
            guard n > 0 else { throw fail("socket_write_failed", "Control socket closed.") }
            offset += n
        }
    }
    var header = Data(count: 4)
    try header.withUnsafeMutableBytes { raw in
        var offset = 0
        while offset < 4 {
            let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), 4 - offset)
            guard n > 0 else { throw fail("socket_read_failed", "No response from service.") }
            offset += n
        }
    }
    let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
    guard length > 0, length <= 24 * 1024 * 1024 else { throw fail("socket_read_failed", "Invalid response size.") }
    var payload = Data(count: length)
    try payload.withUnsafeMutableBytes { raw in
        var offset = 0
        while offset < length {
            let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), length - offset)
            guard n > 0 else { throw fail("socket_read_failed", "Truncated response.") }
            offset += n
        }
    }
    guard let response = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
          response["id"] as? String == id,
          let result = response["result"] as? [String: Any] else { throw fail("socket_read_failed", "Malformed RPC response.") }
    if result["isError"] as? Bool == true { throw fail(result["code"] as? String ?? "native_error", result["message"] as? String ?? "register_capture failed") }
    return result
}

@main struct MacUse {
    @MainActor static func main() {
        guard ProcessInfo.processInfo.machineArchitectureIsARM else { fputs("MacUse requires arm64.\n", stderr); exit(1) }
        var args = Array(CommandLine.arguments.dropFirst())
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
        if bundled {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        if bundled && args.isEmpty {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacUse")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { fputs("Cannot create MacUse support directory: \(error)\n", stderr); exit(1) }
            args = ["serve", "--socket", directory.appendingPathComponent("cu.sock").path, "--allow-app", "com.apple.calculator"]
        }
        if bundled && args == ["--request-permissions"] { args = ["permissions", "--prompt"] }
        if bundled && args.first == "--select-capture" { args = ["select-capture"] + Array(args.dropFirst()) }
        if args.first == "permissions" {
            let result = Engine(allowedApps: []).permissions(prompt: args.contains("--prompt"))
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { fputs("Failed to encode permissions.\n", stderr); exit(1) }
            print(text)
            if args.contains("--prompt"), #available(macOS 15.0, *) {
                fputs("On macOS 15+, also run MacUse Helper with --select-capture once per allowlisted app for screenshots (avoids Sequoia bypass prompts).\n", stderr)
            }
            return
        }
        if args.first == "select-capture" {
            guard #available(macOS 15.0, *) else {
                print("{\"capture_picker\":\"not_required\",\"reason\":\"macOS 14 and earlier use Screen Recording permission only.\"}")
                return
            }
            var allowed = Set<String>()
            var socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacUse/cu.sock").path
            var index = 1
            while index < args.count {
                if args[index] == "--allow-app" {
                    guard index + 1 < args.count else { break }
                    allowed.insert(args[index + 1]); index += 2; continue
                }
                if args[index] == "--socket" {
                    guard index + 1 < args.count else { break }
                    socket = args[index + 1]; index += 2; continue
                }
                fputs("Usage: select-capture [--socket PATH] --allow-app BUNDLE_ID [...]\n", stderr); exit(1)
            }
            if allowed.isEmpty { allowed.insert("com.apple.calculator") }
            do {
                for app in allowed.sorted() {
                    let result = try rpcTool(socket: socket, name: "register_capture", arguments: ["app": app])
                    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
                }
            } catch let error as CUError {
                fputs("\(error.message)\n", stderr); exit(1)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr); exit(1)
            }
            return
        }
        guard args.first == "serve" else {
            print("MacUse (macOS arm64)\n  macuse serve --socket PATH --allow-app BUNDLE_ID [--allow-app BUNDLE_ID ...]\n  macuse permissions [--prompt]\n  macuse select-capture --allow-app BUNDLE_ID   (macOS 15+ screenshot setup)\nRun the MCP bridge separately; see README.md. Service stays in foreground until stopped.")
            return
        }
        var path: String?, allowed = Set<String>()
        var i = 1
        while i < args.count {
            guard i + 1 < args.count else { fputs("Missing option value.\n", stderr); exit(1) }
            switch args[i] { case "--socket": path = args[i+1]; case "--allow-app": allowed.insert(args[i+1]); default: fputs("Unknown option: \(args[i])\n", stderr); exit(1) }
            i += 2
        }
        guard let path, path.hasPrefix("/"), path.utf8.count < 104 else { fputs("Supply an absolute --socket path shorter than 104 UTF-8 bytes.\n", stderr); exit(1) }
        // The caller creates the private directory. Refuse shared or foreign directories and existing paths.
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard validateSocketDirectory(directory) else { fputs("Socket parent must be an existing owner-only directory (chmod 700), not a symlink.\n", stderr); exit(1) }
        var st = stat()
        guard lstat(path, &st) != 0, errno == ENOENT else { fputs("Socket path already exists. Stop its service before removing a stale socket.\n", stderr); exit(1) }
        umask(0o077)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { perror("socket"); exit(1) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.initializeMemory(as: UInt8.self, repeating: 0); path.utf8CString.withUnsafeBytes { bytes in raw.copyBytes(from: bytes) } }
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else { perror("bind/listen"); exit(1) }
        let service = Engine(allowedApps: allowed)
        fputs("MacUse listening at \(path); allowed apps: \(allowed.sorted().joined(separator: ", "))\n", stderr)
        // Signals stop accepting and remove only this service's bound pathname.
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Darwin.close(fd); unlink(path); exit(0) }
            source.resume(); return source
        }
        withExtendedLifetime(sources) {
            DispatchQueue.global().async {
                let slots = DispatchSemaphore(value: 16)
                while true {
                    let client = Darwin.accept(fd, nil, nil)
                    if client < 0 { if errno == EINTR { continue }; break }
                    if slots.wait(timeout: .now() + 5) != .success { Darwin.close(client); continue }
                    Task.detached { await serveConnection(client, engine: service); slots.signal() }
                }
            }
            // Keep the main thread available for AppKit/AX and signal delivery.
            if bundled { NSApplication.shared.run() }
            else { RunLoop.main.run() }
        }
    }
}
extension ProcessInfo {
    var machineArchitectureIsARM: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
