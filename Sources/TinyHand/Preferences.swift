import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let toggleDefault = Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥H")
    static let clearDefault = Shortcut(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥X")
}

enum InteractKey: String, CaseIterable {
    case option, command, control, off

    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .off: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .off: return ""
        }
    }

    var cgFlags: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .control: return .maskControl
        case .off: return []
        }
    }
}

enum InkChoice: String, CaseIterable {
    case match, red, orange, yellow, green, blue, purple, white, black

    var title: String {
        switch self {
        case .match: return "Match the pointer"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .white: return "White"
        case .black: return "Black"
        }
    }

    var color: CGColor? {
        switch self {
        case .match: return nil
        case .red: return Ink.red
        case .orange: return Ink.hex(0xFF8A00)
        case .yellow: return Ink.hex(0xFFCC00)
        case .green: return Ink.hex(0x30C25A)
        case .blue: return Ink.hex(0x0A84FF)
        case .purple: return Ink.hex(0x8754F2)
        case .white: return Ink.hex(0xFFFFFF)
        case .black: return Ink.hex(0x1D1D21)
        }
    }

    func resolved(for style: PointerStyle) -> CGColor {
        color ?? style.inkColor
    }
}

enum Preferences {
    static let changed = Notification.Name("TinyHandPreferencesChanged")
    private static let defaults = UserDefaults.standard

    static var toggleShortcut: Shortcut {
        get { loadShortcut("shortcut.toggle") ?? .toggleDefault }
        set { saveShortcut(newValue, "shortcut.toggle") }
    }

    static var clearShortcut: Shortcut {
        get { loadShortcut("shortcut.clear") ?? .clearDefault }
        set { saveShortcut(newValue, "shortcut.clear") }
    }

    static let pointerSizeRange: ClosedRange<CGFloat> = 0.08...0.20

    static var pointerSize: CGFloat {
        get { (defaults.object(forKey: "pointerSize") as? Double).map { CGFloat($0) } ?? 0.13 }
        set { set(Double(newValue), "pointerSize") }
    }

    static var showShadow: Bool {
        get { defaults.object(forKey: "showShadow") as? Bool ?? true }
        set { set(newValue, "showShadow") }
    }

    static var fadeSeconds: Double {
        get { defaults.object(forKey: "fadeSeconds") as? Double ?? 3 }
        set { set(newValue, "fadeSeconds") }
    }

    static var handSound: Bool {
        get { defaults.object(forKey: "sound.hands") as? Bool ?? true }
        set { set(newValue, "sound.hands") }
    }

    static var tapSound: TapSoundChoice {
        get { defaults.string(forKey: "tapSound").flatMap(TapSoundChoice.init(rawValue:)) ?? .thock }
        set { set(newValue.rawValue, "tapSound") }
    }

    static var laserSound: Bool {
        get { defaults.object(forKey: "sound.laser") as? Bool ?? false }
        set { set(newValue, "sound.laser") }
    }

    static var interactKeepsHand: Bool {
        get { defaults.bool(forKey: "interactKeepsHand") }
        set { set(newValue, "interactKeepsHand") }
    }

    static var interactKey: InteractKey {
        get { defaults.string(forKey: "interactKey").flatMap(InteractKey.init(rawValue:)) ?? .option }
        set { set(newValue.rawValue, "interactKey") }
    }

    static var inkChoice: InkChoice {
        get { defaults.string(forKey: "inkChoice").flatMap(InkChoice.init(rawValue:)) ?? .match }
        set { set(newValue.rawValue, "inkChoice") }
    }

    static var showInkButton: Bool {
        get { defaults.object(forKey: "showInkButton") as? Bool ?? true }
        set { set(newValue, "showInkButton") }
    }

    static let maxPinned = 8

    static var pinnedStyles: [PointerStyle] {
        get {
            guard let raw = defaults.stringArray(forKey: "pinnedStyles") else {
                return PointerStyle.defaultPinned
            }
            var seen = Set<PointerStyle>()
            let pinned = raw.compactMap(PointerStyle.init(rawValue:)).filter { seen.insert($0).inserted }
            return pinned.isEmpty ? PointerStyle.defaultPinned : pinned
        }
        set { set(newValue.map(\.rawValue), "pinnedStyles") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.write("launch at login change failed: \(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func resetAll() {
        for key in ["shortcut.toggle", "shortcut.clear", "pointerSize", "showShadow", "fadeSeconds",
                    "sound.hands", "sound.laser", "interactKey", "interactKeepsHand", "pinnedStyles", "pointerStyle",
                    "inkChoice", "showInkButton", "tapSound"] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static var batchDepth = 0

    static func performBatch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        if batchDepth == 0 { NotificationCenter.default.post(name: changed, object: nil) }
    }

    private static func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        if batchDepth == 0 { NotificationCenter.default.post(name: changed, object: nil) }
    }

    private static func loadShortcut(_ key: String) -> Shortcut? {
        guard let d = defaults.dictionary(forKey: key),
              let code = d["keyCode"] as? Int, let mods = d["modifiers"] as? Int, let label = d["display"] as? String else {
            return nil
        }
        return Shortcut(keyCode: UInt32(code), modifiers: UInt32(mods), display: label)
    }

    private static func saveShortcut(_ s: Shortcut, _ key: String) {
        set(["keyCode": Int(s.keyCode), "modifiers": Int(s.modifiers), "display": s.display], key)
    }
}
