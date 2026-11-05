import Foundation
import AppKit
import Darwin

struct Failure: Error, CustomStringConvertible {
    let description: String
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}

// Independent test client: does not import production framing or UI implementation.
final class NativeClient {
    let path: String
    init(path: String) { self.path = path }
    func request(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        try check(path.utf8.count < 104, "Socket path too long")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try check(fd >= 0, "socket failed")
        defer { close(fd) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in path.utf8CString.withUnsafeBytes { raw.copyBytes(from: $0) } }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try check(status == 0, "connect: \(String(cString: strerror(errno)))")
        let id = UUID().uuidString
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":id, "method":method, "params":params])
        var size = UInt32(body.count).littleEndian
        let frame = withUnsafeBytes(of: &size) { Data($0) } + body
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < frame.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), frame.count - offset)
                if n < 0 && errno == EINTR { continue }
                try check(n > 0, "socket write failed")
                offset += n
            }
        }
        func read(_ count: Int) throws -> Data {
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < count {
                    let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                    if n < 0 && errno == EINTR { continue }
                    try check(n > 0, "socket closed or timed out")
                    offset += n
                }
            }
            return data
        }
        let header = try read(4)
        let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        try check(length > 0 && length <= 24 * 1024 * 1024, "Invalid response size")
        guard let response = try JSONSerialization.jsonObject(with: read(length)) as? [String: Any], response["id"] as? String == id,
              let result = response["result"] as? [String: Any] else { throw Failure(description: "Invalid RPC response") }
        return result
    }
    func call(_ name: String, _ args: [String: Any] = [:], session: String) throws -> [String: Any] {
        try request("tools/call", params: ["session_id":session, "name":name, "arguments":args])
    }
}
func success(_ value: [String: Any]) throws -> [String: Any] {
    try check(value["isError"] as? Bool != true, "Native error: \(value)")
    return value
}
func runOpen(_ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = args
    try process.run(); process.waitUntilExit()
    try check(process.terminationStatus == 0, "open failed: \(args)")
}
func target(_ state: [String: Any]) throws -> [String: Any] {
    guard let app = state["app"] as? String, let snapshot = state["snapshot_id"] as? String else { throw Failure(description: "Missing target in state") }
    return ["app":app, "snapshot_id":snapshot]
}
func shows42(_ state: [String: Any]) throws {
    let text = (state["state"] as? String ?? "").filter { ![0x200e,0x200f,0x2066,0x2067,0x2068,0x2069].contains($0.unicodeScalars.first?.value ?? 0) }
    try check(text.range(of: #"(?m)^\s*\d+ AXStaticText 42\s*$"#, options: .regularExpression) != nil, "Calculator did not show 42: \(text)")
}

@main struct NativeE2E {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let socket = env["MACUSE_SOCKET"] ?? env["NATIVE_CU_SOCKET"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacUse/cu.sock").path
        let app = env["MACUSE_APP"] ?? env["NATIVE_CU_APP"] ?? root.appendingPathComponent("dist/MacUse Helper.app").path
        let output = URL(fileURLWithPath: env["MACUSE_E2E_OUTPUT"] ?? env["NATIVE_CU_E2E_OUTPUT"] ?? root.appendingPathComponent(".build/e2e/swift-\(UUID().uuidString)").path)
        let client = NativeClient(path: socket)
        let session = "swift-e2e-\(UUID().uuidString)", other = "swift-e2e-\(UUID().uuidString)"
        var cases: [[String: Any]] = [], failed = false
        var report: [String: Any] = ["suite":"swift-native-e2e", "app":app, "socket":socket]
        func test(_ name: String, _ action: () throws -> Void) throws {
            do { try action(); cases.append(["name":name,"status":"passed"]); print("PASS \(name)") }
            catch { cases.append(["name":name,"status":"failed","message":String(describing:error)]); throw error }
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try test("LaunchServices App startup/reuse and arm64 socket") {
                try runOpen(["-g",app])
                var ping: [String: Any] = [:]
                for _ in 0..<40 { do { ping = try client.request("ping"); break } catch { Thread.sleep(forTimeInterval: 0.1) } }
                try check(ping["architecture"] as? String == "arm64" && ping["serverApiVersion"] as? String == "MacUse-1", "App service unavailable")
            }
            try test("App permissions") {
                let permissions = try success(client.call("check_permissions",session:session)); report["permissions"] = permissions
                try check(permissions["accessibility"] as? Bool == true, "Authorize App Accessibility")
                try check(permissions["screen_recording"] as? Bool == true, "Authorize screen recording and restart App")
            }
            var current: [String: Any] = [:]
            try test("Calculator inventory and AX state") {
                try runOpen(["-a","Calculator"])
                for _ in 0..<40 {
                    current = try client.call("get_app_state",["app":"com.apple.calculator"],session:session)
                    if current["code"] as? String != "window_unavailable" { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                current = try success(current)
                try check((current["state"] as? String ?? "").contains("AXWindow"), "Missing AX window")
                let inventory = try success(client.call("list_apps",session:session))
                try check((inventory["apps"] as? [[String:Any]] ?? []).contains { $0["app"] as? String == "com.apple.calculator" && $0["allowed"] as? Bool == true }, "Calculator not allowlisted")
            }
            try test("Session isolation") {
                var args = try target(current); args["key"] = "Escape"
                let rejected = try client.call("press_key",args,session:other)
                try check(rejected["code"] as? String == "snapshot_required", "Cross-session snapshot accepted")
            }
            try test("Keyboard calculation 12+30=42 across reconnects") {
                for (name, extra) in [("press_key",["key":"Escape"]),("type_text",["text":"12+30"]),("press_key",["key":"Return"])] {
                    var args = try target(current); args.merge(extra) { _,new in new }
                    let previous = current["snapshot_id"] as? String
                    current = try success(client.call(name,args,session:session))
                    try check(current["snapshot_id"] as? String != previous, "Snapshot did not rotate")
                }
                try shows42(current)
            }
            try test("Stale snapshot rejected without changing result") {
                var args = try target(current); args["key"] = "Escape"
                current = try success(client.call("get_app_state",["app":"com.apple.calculator"],session:session))
                let rejected = try client.call("press_key",args,session:session)
                try check(rejected["code"] as? String == "stale_snapshot", "Stale snapshot accepted")
                current = try success(client.call("get_app_state",["app":"com.apple.calculator"],session:session)); try shows42(current)
            }
            try test("AX button clicks 4 and 2") {
                var args = try target(current); args["key"] = "Escape"
                current = try success(client.call("press_key",args,session:session))
                for digit in ["4","2"] {
                    let lines = (current["state"] as? String ?? "").components(separatedBy:"\n")
                    guard let line = lines.first(where: { $0.range(of: "^\\s*\\d+ AXButton \(digit) \\[actions:", options:.regularExpression) != nil }),
                          let token = line.split(separator:" ").first, let index = Int(token) else { throw Failure(description:"Missing digit button \(digit)") }
                    var input = try target(current); input["element_index"] = index
                    current = try success(client.call("click",input,session:session))
                }
                try shows42(current)
            }
            try test("Window PNG signature and dimensions") {
                let image = try success(client.call("get_screenshot",target(current),session:session))
                guard let encoded = image["data"] as? String, let bytes = Data(base64Encoded:encoded), bytes.count >= 24 else { throw Failure(description:"Missing PNG") }
                try check(bytes.prefix(8).elementsEqual([137,80,78,71,13,10,26,10]), "Invalid PNG signature")
                func dimension(_ offset:Int) -> Int { bytes[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) } }
                try check(dimension(16) == image["width"] as? Int && dimension(20) == image["height"] as? Int && dimension(16)>0 && dimension(20)>0, "PNG dimensions mismatch")
                try bytes.write(to:output.appendingPathComponent("calculator.png"))
            }
            try test("Session cleanup keeps service available") {
                _ = try client.call("end_session",session:session)
                let rejected = try client.call("get_screenshot",target(current),session:session)
                try check(rejected["code"] as? String == "snapshot_required", "Session not discarded")
                _ = try client.request("ping")
            }
        } catch { failed = true; report["error"] = String(describing:error); fputs("FAIL \(error)\n",stderr) }
        for id in [session,other] { do { _ = try client.call("end_session",session:id) } catch { failed=true; fputs("Cleanup failed: \(error)\n",stderr) } }
        report["cases"] = cases
        do { let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]); try data.write(to:output.appendingPathComponent("report.json")) }
        catch { failed=true; fputs("Report failed: \(error)\n",stderr) }
        print("Swift E2E artifacts: \(output.path)")
        exit(failed ? 1 : 0)
    }
}
