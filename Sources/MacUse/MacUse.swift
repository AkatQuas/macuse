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
    init(allowedApps: Set<String>) { self.allowedApps = allowedApps }

    func permissions(prompt: Bool = false) -> [String: Any] {
        let trusted = prompt ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) : AXIsProcessTrusted()
        let screen = prompt ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()
        return ["accessibility": trusted, "screen_recording": screen]
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
        if args.first == "permissions" {
            let result = Engine(allowedApps: []).permissions(prompt: args.contains("--prompt"))
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { fputs("Failed to encode permissions.\n", stderr); exit(1) }
            print(text)
            return
        }
        guard args.first == "serve" else {
            print("MacUse (macOS arm64)\n  macuse serve --socket PATH --allow-app BUNDLE_ID [--allow-app BUNDLE_ID ...]\n  macuse permissions [--prompt]\nRun the MCP bridge separately; see README.md. Service stays in foreground until stopped.")
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
