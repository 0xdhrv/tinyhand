import AppKit

// In-memory native dependencies: tests never touch the installed app, user defaults, or input taps.
enum InkChoice: String { case match, red, orange, yellow, green, blue, purple, white, black }
enum TapSoundChoice: String { case thock, click, pop, wood, boop, squeak }
struct PointerStyle: Hashable {
    let rawValue: String
    init?(rawValue: String) {
        guard ["lavender", "laser", "custom-one"].contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }
    static let laser = PointerStyle(rawValue: "laser")!
    static var saved = PointerStyle(rawValue: "lavender")!
    static var allCases: [PointerStyle] { [PointerStyle(rawValue: "lavender")!, laser, PointerStyle(rawValue: "custom-one")!] }
    var title: String { rawValue }
    var isCustom: Bool { rawValue == "custom-one" }
    var assetName: String? { nil }
}
enum HandAsset {
    static func thumbnail(_ name: String) -> NSImage? { nil }
    static func load(_ name: String) -> NSImage? { nil }
}
enum Preferences {
    static let changed = Notification.Name("TinyHandPreferencesChanged")
    static var inkChoice = InkChoice.match
    static var fadeSeconds = 3.0
    static var pointerSize: CGFloat = 0.13
    static var showShadow = true
    static var handSound = true
    static var laserSound = false
    static var tapSound = TapSoundChoice.thock
    static let pointerSizeRange: ClosedRange<CGFloat> = 0.08...0.20
    static let maxPinned = 8
    static var pinnedStyles = [PointerStyle.saved, PointerStyle.laser]
    static var batchCount = 0
    static func performBatch(_ body: () -> Void) { body(); batchCount += 1 }
}
final class OverlayController {
    var isActive = false
    var canActivate = true
    var strokes = 3
    var style: PointerStyle { PointerStyle.saved }
    func activate() -> Bool { isActive = true; return canActivate }
    func deactivate() { isActive = false }
    func clearInk() { strokes = 0 }
    func pick(_ style: PointerStyle) { PointerStyle.saved = style }
}
