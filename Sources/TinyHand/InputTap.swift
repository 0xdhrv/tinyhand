import AppKit

final class InputTap {
    var onMouseDown: (() -> Void)?
    var onInteractDown: (() -> Void)?
    var onInteractUp: (() -> Void)?
    var onMouseUp: (() -> Void)?
    var onLeftDragged: (() -> Void)?
    var onPassThroughPress: ((CGPoint) -> Void)?

    private let lock = NSLock()
    private var _active = false
    private var _passThroughRects: [CGRect] = []
    private var _interactKey: CGEventFlags = []
    private var _interactPress = false

    var passThroughRects: [CGRect] {
        get { lock.withLock { _passThroughRects } }
        set { lock.withLock { _passThroughRects = newValue } }
    }

    private var active: Bool {
        lock.withLock { _active }
    }

    var interactKey: CGEventFlags {
        get { lock.withLock { _interactKey } }
        set { lock.withLock { _interactKey = newValue } }
    }

    var interactPressing: Bool {
        lock.withLock { _interactPress }
    }

    private var passingThrough = false
    private(set) var maxWaitMs: Double = 0
    private var tap: CFMachPort?
    private var thread: Thread?

    private(set) var isInstalled = false

    @discardableResult
    func install() -> Bool {
        guard tap == nil else {
            return true
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let me = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "TinyHand event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        self.tap = tap
        self.thread = thread
        isInstalled = true
        return true
    }

    func setActive(_ value: Bool) {
        lock.withLock {
            _active = value
            _interactPress = false
        }
        guard let tap = tap else {
            return
        }
        CGEvent.tapEnable(tap: tap, enable: value)
    }

    func simulate(_ type: CGEventType) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left) else {
            return
        }
        let was = active
        lock.withLock { _active = true }
        _ = handle(type: type, event: event)
        lock.withLock { _active = was }
    }

    func resetWait() {
        maxWaitMs = 0
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.timestamp > 0 {
            let wait = Double(DispatchTime.now().uptimeNanoseconds &- event.timestamp) / 1_000_000
            if wait < 600_000 {
                maxWaitMs = max(maxWaitMs, wait)
            }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout {
                Log.write("event tap was disabled by a timeout; re-enabled")
            }
            if active, let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard active else {
            return Unmanaged.passUnretained(event)
        }

        let key = interactKey
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !key.isEmpty && (event.flags.contains(key) || CGEventSource.flagsState(.hidSystemState).contains(key)) {
                lock.withLock { _interactPress = true }
                DispatchQueue.main.async { [weak self] in self?.onInteractDown?() }
            }
        default:
            break
        }
        if lock.withLock({ _interactPress }) {
            event.flags.remove(key)
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                lock.withLock { _interactPress = false }
                DispatchQueue.main.async { [weak self] in self?.onInteractUp?() }
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            passingThrough = passThroughRects.contains { $0.contains(event.location) }
            if passingThrough {
                let location = event.location
                DispatchQueue.main.async { [weak self] in self?.onPassThroughPress?(location) }
            }
        default:
            break
        }
        if passingThrough {
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                passingThrough = false
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            DispatchQueue.main.async { [weak self] in self?.onMouseDown?() }
            return nil
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            DispatchQueue.main.async { [weak self] in self?.onMouseUp?() }
            return nil
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if type == .leftMouseDragged {
                DispatchQueue.main.async { [weak self] in self?.onLeftDragged?() }
            }
            event.type = .mouseMoved
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
