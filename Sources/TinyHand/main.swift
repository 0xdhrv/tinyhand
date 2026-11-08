import AppKit
import ApplicationServices

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--ctl" {
    exit(ControlTransport.runCLI(Array(CommandLine.arguments.dropFirst(2))))
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-test") {
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/armtest.png"
    RenderTest.run(outPath: out)
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--ax-status") {
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/tinyhand-ax.txt"
    let mask: CGEventMask = 1 << CGEventType.leftMouseDown.rawValue
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil)
    let text = "trusted=\(AXIsProcessTrusted()) tap=\(tap != nil) bundle=\(Bundle.main.bundlePath)\n"
    try? text.write(toFile: out, atomically: true, encoding: .utf8)
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--toolbar-test") {
    _ = NSApplication.shared
    let bar = Toolbar()
    bar.select(.lavender)
    bar.setNeedsPermission(CommandLine.arguments.contains("--needs-permission"))
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/toolbar.png"
    if let data = bar.snapshot()?.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: out))
        print("rendered \(out)")
    }
    if CommandLine.arguments.contains("--hint") {
        bar.showHint([("Click", "to tap"), ("Drag", "to draw"), ("Hold ⌥", "to click for real"), ("Esc", "to exit")])
        if let data = bar.snapshotHint()?.representation(using: .png, properties: [:]) {
            let hintOut = out.replacingOccurrences(of: ".png", with: "-hint.png")
            try? data.write(to: URL(fileURLWithPath: hintOut))
            print("rendered \(hintOut)")
        }
    }
    if CommandLine.arguments.contains("--ink"), let data = bar.snapshotInkTray()?.representation(using: .png, properties: [:]) {
        let trayOut = out.replacingOccurrences(of: ".png", with: "-ink.png")
        try? data.write(to: URL(fileURLWithPath: trayOut))
        print("rendered \(trayOut)")
    }
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--settings-test") {
    _ = NSApplication.shared
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/settings.png"
    let section = CommandLine.arguments.count > idx + 2 ? SettingsSection(rawValue: CommandLine.arguments[idx + 2]) ?? .general : .general
    let dark = ProcessInfo.processInfo.environment["TH_DARK"] != nil
    if let image = SettingsWindow().snapshot(section, dark: dark),
       let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: out))
        print("rendered \(out)")
    }
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--welcome-test") {
    _ = NSApplication.shared
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/welcome.png"
    let welcome = WelcomeWindow()
    welcome.simulateUntrusted = CommandLine.arguments.contains("--untrusted")
    if let data = welcome.snapshot()?.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: out))
        print("rendered \(out)")
    }
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--make-hand"), CommandLine.arguments.count > idx + 2 {
    let input = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
    let output = URL(fileURLWithPath: CommandLine.arguments[idx + 2])
    do {
        let made = try HandMaker.make(from: input)
        try HandMaker.write(made.image, to: output)
        print(String(format: "ok %06X", made.ink))
    } catch let problem as HandMaker.Problem {
        print("rejected: \(problem.message)")
        exit(1)
    } catch {
        print("failed: \(error)")
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments.contains("--e2e-test") {
    E2ETest.run()
    exit(0)
}

if CommandLine.arguments.contains("--click-test") {
    _ = NSApplication.shared
    OverlayController().runClickTest()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
