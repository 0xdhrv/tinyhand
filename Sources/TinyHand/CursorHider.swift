import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum CursorHider {
    private static var hidden = false

    private typealias MainConn = @convention(c) () -> Int32
    private typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static let backgroundHidingSymbols: (MainConn, SetProp)? = {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            return nil
        }
        guard let mainConnSym = dlsym(handle, "CGSMainConnectionID"),
              let setPropSym = dlsym(handle, "CGSSetConnectionProperty") else {
            return nil
        }
        return (unsafeBitCast(mainConnSym, to: MainConn.self), unsafeBitCast(setPropSym, to: SetProp.self))
    }()

    static func enableBackgroundHiding() {
        guard let (mainConn, setProp) = backgroundHidingSymbols else {
            return
        }
        let cid = mainConn()
        _ = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    static func hide() {
        guard !hidden else {
            return
        }
        hidden = true
        hideCount = 1
        hiddenAt = Date()
        CGDisplayHideCursor(CGMainDisplayID())
    }

    static func show() {
        guard hidden else {
            return
        }
        hidden = false
        for _ in 0..<hideCount {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        hideCount = 0
    }

    static var isSettling: Bool {
        hidden && Date().timeIntervalSince(hiddenAt) < 1
    }

    private static var hideCount = 0
    private static var lastSeed: Int32 = 0
    private static var lastReassert = Date.distantPast
    private static var hiddenAt = Date.distantPast

    private static let cursorSeed: (() -> Int32)? = {
        typealias Seed = @convention(c) () -> Int32
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGSCurrentCursorSeed") else {
            return nil
        }
        return unsafeBitCast(sym, to: Seed.self)
    }()

    static func reassert(fighting: Bool = false, urgent: Bool = false) {
        guard hidden else {
            return
        }
        let seed = cursorSeed?() ?? 0
        let interval = urgent ? 0 : fighting ? 0.03 : Date().timeIntervalSince(hiddenAt) < 1 ? 0.05 : 1.0
        guard seed != lastSeed || Date().timeIntervalSince(lastReassert) > interval else {
            return
        }
        lastSeed = seed
        lastReassert = Date()
        enableBackgroundHiding()
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }
}

enum DockArea {
    private static let lock = NSLock()
    private static var frame: CGRect = .null
    private static var lastRead = Date.distantPast
    private static var reading = false
    private static let queue = DispatchQueue(label: "TinyHand.dock-area", qos: .utility)

    static func contains(_ cgPoint: CGPoint) -> Bool {
        let (known, refresh) = lock.withLock { () -> (CGRect, Bool) in
            let due = !reading && Date().timeIntervalSince(lastRead) > 1
            if due {
                reading = true
                lastRead = Date()
            }
            return (frame, due)
        }
        if refresh {
            queue.async {
                let fresh = read()
                lock.withLock {
                    frame = fresh
                    reading = false
                }
            }
        }
        return known.insetBy(dx: -8, dy: -8).contains(cgPoint)
    }

    private static func read() -> CGRect {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return .null
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = (children as? [AXUIElement])?.first else {
            return .null
        }
        var pos: CFTypeRef?
        var size: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &size)
        var origin = CGPoint.zero
        var extent = CGSize.zero
        if let pos = pos, CFGetTypeID(pos) == AXValueGetTypeID() {
            AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
        }
        if let size = size, CFGetTypeID(size) == AXValueGetTypeID() {
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        }
        return extent == .zero ? .null : CGRect(origin: origin, size: extent)
    }
}
