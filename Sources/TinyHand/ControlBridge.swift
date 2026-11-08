import AppKit
import ApplicationServices

final class ControlBridge {
    private let server = ControlServer()
    private let overlay: OverlayController
    private let openSettings: () -> Void
    private let openHandCreator: () -> Void
    private let accessibility: () -> Bool
    static let operations = ["status", "styles", "on", "off", "toggle", "clear", "style", "laser", "configure", "toggle-sound", "pin", "settings", "custom-hands"]

    init(overlay: OverlayController, accessibility: @escaping () -> Bool = { AXIsProcessTrusted() }, openSettings: @escaping () -> Void, openHandCreator: @escaping () -> Void) {
        self.overlay = overlay
        self.accessibility = accessibility
        self.openSettings = openSettings
        self.openHandCreator = openHandCreator
    }

    func start() throws { try server.start { [weak self] data in self?.handle(data) ?? Data() } }
    func stop() { server.stop() }

    struct Problem: Error { let code: String; let message: String }
    private func reject(_ message: String, code: String = "invalid-request") -> Problem {
        Problem(code: code, message: message)
    }

    func handle(_ data: Data) -> Data {
        var response: [String: Any] = ["version": ControlTransport.version]
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = request["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
                  version.doubleValue == 1,
                  let op = request["operation"] as? String, Self.operations.contains(op) else {
                throw reject("Unsupported protocol version or operation")
            }
            var allowed: Set<String> = ["version", "operation"]
            if op == "style" { allowed.formUnion(["style", "activate"]) }
            if op == "configure" { allowed.insert("settings") }
            if op == "pin" { allowed.formUnion(["style", "pinned"]) }
            guard Set(request.keys).isSubset(of: allowed) else { throw reject("Unexpected request fields") }
            switch op {
            case "on": try activate()
            case "off": overlay.deactivate()
            case "toggle":
                if overlay.isActive { overlay.deactivate() } else { try activate() }
            case "clear": overlay.clearInk()
            case "style":
                let style = try readStyle(request["style"])
                let shouldActivate = try readBool(request["activate"] ?? false)
                try validateAsset(for: style)
                if shouldActivate { try activate() }
                overlay.pick(style)
                NotificationCenter.default.post(name: Preferences.changed, object: nil)
            case "laser":
                try activate()
                overlay.pick(.laser)
                NotificationCenter.default.post(name: Preferences.changed, object: nil)
            case "configure":
                guard let patch = request["settings"] as? [String: Any], !patch.isEmpty else { throw reject("Settings are required") }
                try configure(patch)
            case "toggle-sound": Preferences.handSound.toggle()
            case "pin":
                let style = try readStyle(request["style"])
                let pinned = try readBool(request["pinned"])
                var styles = Preferences.pinnedStyles
                if pinned && !styles.contains(style) {
                    guard styles.count < Preferences.maxPinned else { throw reject("The toolbar already has eight pointers", code: "toolbar-full") }
                    styles.append(style)
                } else if !pinned {
                    styles.removeAll { $0 == style }
                    guard !styles.isEmpty else { throw reject("Keep at least one pointer pinned") }
                }
                Preferences.pinnedStyles = styles
            case "settings": openSettings()
            case "custom-hands": openHandCreator()
            default: break
            }
            response["ok"] = true
            response["state"] = state()
            if op == "styles" { response["styles"] = styles() }
        } catch {
            let problem = error as? Problem
            response["ok"] = false
            response["error"] = ["code": problem?.code ?? "invalid-request", "message": problem?.message ?? "Malformed control request"]
            response["state"] = state()
        }
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
    }

    private func activate() throws {
        guard accessibility() else { throw reject("Allow TinyHand in System Settings → Privacy & Security → Accessibility", code: "accessibility") }
        let wasActive = overlay.isActive
        guard overlay.activate() else {
            if !wasActive { overlay.deactivate() }
            throw reject("TinyHand could not start intercepting mouse input. Relaunch TinyHand and try again.", code: "activation-failed")
        }
    }

    private func readStyle(_ value: Any?) throws -> PointerStyle {
        guard let id = value as? String, let style = PointerStyle(rawValue: id) else { throw reject("This pointer is no longer available. Refresh the pointer list.", code: "unknown-style") }
        return style
    }

    private func validateAsset(for style: PointerStyle) throws {
        if let asset = style.assetName, HandAsset.load(asset) == nil {
            throw reject("TinyHand could not load the image for this pointer.", code: "missing-asset")
        }
    }

    private func readBool(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw reject("Expected a boolean") }
        return number.boolValue
    }

    private func readNumber(_ value: Any) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw reject("Expected a finite number") }
        return number.doubleValue
    }

    /// Validate every field before writing anything; deliver one native settings notification.
    private func configure(_ patch: [String: Any]) throws {
        let allowed: Set<String> = ["style", "ink", "fade", "size", "shadow", "handSound", "laserSound", "tapSound"]
        guard Set(patch.keys).isSubset(of: allowed) else { throw reject("Unsupported setting") }
        let style = try patch["style"].map { try readStyle($0) }
        if let style { try validateAsset(for: style) }
        let ink = patch["ink"].flatMap { ($0 as? String).flatMap(InkChoice.init(rawValue:)) }
        if patch["ink"] != nil && ink == nil { throw reject("Unknown ink color") }
        let sound = patch["tapSound"].flatMap { ($0 as? String).flatMap(TapSoundChoice.init(rawValue:)) }
        if patch["tapSound"] != nil && sound == nil { throw reject("Unknown tap sound") }
        let fade = try patch["fade"].map { try readNumber($0) }
        if let fade = fade, ![0.0, 3, 6, 10].contains(fade) { throw reject("Fade must be 0, 3, 6, or 10 seconds") }
        let size = try patch["size"].map { try readNumber($0) }
        if let size = size, !Preferences.pointerSizeRange.contains(CGFloat(size)) { throw reject("Pointer size is outside the native range") }
        let shadow = try patch["shadow"].map { try readBool($0) }
        let handSound = try patch["handSound"].map { try readBool($0) }
        let laserSound = try patch["laserSound"].map { try readBool($0) }
        Preferences.performBatch {
            if let style = style { PointerStyle.saved = style }
            if let ink = ink { Preferences.inkChoice = ink }
            if let fade = fade { Preferences.fadeSeconds = fade }
            if let size = size { Preferences.pointerSize = CGFloat(size) }
            if let shadow = shadow { Preferences.showShadow = shadow }
            if let handSound = handSound { Preferences.handSound = handSound }
            if let laserSound = laserSound { Preferences.laserSound = laserSound }
            if let sound = sound { Preferences.tapSound = sound }
        }
    }

    private func state() -> [String: Any] {
        ["running": true, "active": overlay.isActive, "style": overlay.style.rawValue,
         "accessibility": accessibility(), "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
         "capabilities": Self.operations,
         "settings": ["ink": Preferences.inkChoice.rawValue, "fade": Preferences.fadeSeconds,
                      "size": Double(Preferences.pointerSize), "shadow": Preferences.showShadow,
                      "handSound": Preferences.handSound, "laserSound": Preferences.laserSound, "tapSound": Preferences.tapSound.rawValue],
         "sizeRange": [Double(Preferences.pointerSizeRange.lowerBound), Double(Preferences.pointerSizeRange.upperBound)],
         "pinned": Preferences.pinnedStyles.map(\.rawValue)]
    }

    private func styles() -> [[String: Any]] {
        PointerStyle.allCases.map { style in
            var item: [String: Any] = ["id": style.rawValue, "name": style.title, "type": style == .laser ? "laser" : style.isCustom ? "custom" : "hand"]
            // Use TinyHand's own cropped 128px thumbnails, including custom hands.
            if let name = style.assetName, let image = HandAsset.thumbnail(name),
               let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                // Encode the ID rather than treating custom asset IDs as path components.
                let filename = Data(style.rawValue.utf8).map { String(format: "%02x", $0) }.joined() + ".png"
                let url = URL(fileURLWithPath: ControlTransport.directory).appendingPathComponent(filename)
                if (try? png.write(to: url, options: .atomic)) != nil { item["thumbnail"] = url.path }
            }
            return item
        }
    }
}
