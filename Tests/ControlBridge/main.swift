import AppKit
import Darwin

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
    checks += 1
}
let overlay = OverlayController()
var permitted = true
var creatorOpened = false
let bridge = ControlBridge(overlay: overlay, accessibility: { permitted }, openSettings: {}, openHandCreator: { creatorOpened = true })
func send(_ operation: String, _ fields: [String: Any] = [:]) -> [String: Any] {
    var request = fields
    request["version"] = 1
    request["operation"] = operation
    let data = try! JSONSerialization.data(withJSONObject: request)
    return try! JSONSerialization.jsonObject(with: bridge.handle(data)) as! [String: Any]
}
func success(_ response: [String: Any]) -> Bool { response["ok"] as? Bool == true }
check(success(send("custom-hands")) && creatorOpened, "opens native custom hand creator")
check(success(send("on")), "on succeeds")
check(success(send("on")) && overlay.isActive, "on is idempotent")
let selected = overlay.style
check(success(send("clear")) && overlay.strokes == 0 && overlay.isActive && overlay.style == selected, "clear preserves active pointer")
check(success(send("off")) && success(send("off")) && !overlay.isActive, "off is idempotent")
check(success(send("toggle")) && overlay.isActive, "toggle activates")
check(success(send("toggle")) && !overlay.isActive, "toggle deactivates")
permitted = false
check(!success(send("laser")) && overlay.style == selected && !overlay.isActive, "permission failure preserves pointer")
permitted = true
check(success(send("laser")) && overlay.style == .laser && overlay.isActive, "laser activates")
check(Preferences.handSound && !Preferences.laserSound && Preferences.inkChoice == .match, "laser preserves sound and ink")
check(!success(send("style", ["style": "removed", "activate": true])) && overlay.style == .laser, "unknown pointer rejected")
check(success(send("style", ["style": "custom-one", "activate": false])) && overlay.style.isCustom, "custom pointer works")
check(!success(send("configure", ["settings": ["ink": "red", "size": 999]])) && Preferences.inkChoice == .match, "invalid preset changes nothing")
check(!success(send("configure", ["settings": ["handSound": 1]])), "numeric boolean rejected")
check(!success(send("configure", ["settings": ["size": true]])), "boolean size rejected")
check(!success(send("configure", ["settings": ["shell": "anything"]])), "unknown settings rejected")
check(!success(send("clear", ["extra": true])), "unexpected request fields rejected")
check(success(send("configure", ["settings": ["style": "lavender", "ink": "red", "fade": 6, "handSound": false]])), "atomic preset applied")
check(Preferences.batchCount == 1 && overlay.style.rawValue == "lavender" && Preferences.inkChoice == .red && !Preferences.handSound, "one settings batch")
check(success(send("toggle-sound")) && Preferences.handSound && !Preferences.laserSound, "hand sound independent")
check(success(send("pin", ["style": "custom-one", "pinned": true])) && Preferences.pinnedStyles.contains(PointerStyle(rawValue: "custom-one")!), "custom pointer pinned")
let styles = send("styles")["styles"] as! [[String: Any]]
check(styles.count == 3 && styles.contains { $0["type"] as? String == "custom" }, "native style discovery")
overlay.deactivate(); overlay.canActivate = false
check(!success(send("on")) && !overlay.isActive, "input tap failure rolls back activation")

// Exercise the real private Unix socket with a client on another queue.
let server = ControlServer()
try server.start { bridge.handle($0) }
var secondServerRejected = false
let second = ControlServer()
do { try second.start { $0 } } catch { secondServerRejected = true }
check(secondServerRejected, "second server cannot replace live endpoint")
var info = stat()
check(lstat(ControlTransport.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "socket has private permissions")
DispatchQueue.global().async {
    do {
        let request = Data("{\"version\":1,\"operation\":\"status\"}".utf8)
        let response = try ControlTransport.request(request)
        let object = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        guard object["ok"] as? Bool == true else { exit(1) }
        // An oversized request is rejected before it can reach a native handler.
        var rejected = false
        do { _ = try ControlTransport.request(Data(repeating: 65, count: ControlTransport.requestLimit + 1)) } catch { rejected = true }
        guard rejected else { exit(1) }
        DispatchQueue.main.async {
            server.stop()
            print("Passed \(checks + 2) native bridge checks")
            // Allow the cancellation handler to remove its private test socket.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }
        }
    } catch { fputs("Socket test failed: \(error)\n", stderr); exit(1) }
}
DispatchQueue.global().asyncAfter(deadline: .now() + 8) { fputs("Native tests timed out\n", stderr); exit(1) }
dispatchMain()
