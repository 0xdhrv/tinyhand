import AppKit
import Darwin

/// One newline-delimited JSON request per connection. No network listener.
enum ControlTransport {
    static let version = 1
    static let directory: String = {
        // confstr returns the same per-user path for LaunchServices and CLI clients.
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &path, path.count) > 0 else { return "" }
        #if CONTROL_TEST
        let id = "tinyhand-test-\(getpid())"
        #else
        guard let id = Bundle.main.bundleIdentifier else { return "" }
        #endif
        return String(cString: path) + id + ".ctl"
    }()
    static let path = directory + "/s"
    static let requestLimit = 16_384
    static let responseLimit = 2_097_152

    struct Failure: Error {
        let message: String
        var code = "unavailable"
    }

    static func secureDirectory() throws {
        guard !directory.isEmpty,
              path.utf8CString.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw Failure(message: "Cannot resolve the TinyHand control endpoint")
        }
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            throw Failure(message: "Cannot create control directory")
        }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw Failure(message: "Unsafe control directory")
        }
    }

    static func address() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            path.utf8CString.withUnsafeBytes { source in dest.copyBytes(from: source) }
        }
        return addr
    }

    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 1, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func readLine(_ fd: Int32, limit: Int, deadline: DispatchTime) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit && DispatchTime.now() < deadline {
            let count = read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure(message: "Control connection closed or timed out") }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<newline])
                guard data.count <= limit else { break }
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw Failure(message: "Control message exceeds size or time limit")
    }

    static func writeLine(_ fd: Int32, data: Data) throws {
        var frame = data
        frame.append(10)
        try frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            let deadline = DispatchTime.now() + .seconds(2)
            while sent < bytes.count {
                guard DispatchTime.now() < deadline else { throw Failure(message: "Control connection timed out") }
                let count = write(fd, base.advanced(by: sent), bytes.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure(message: "Cannot write control response") }
                sent += count
            }
        }
    }

    static func request(_ data: Data) throws -> Data {
        guard data.count <= requestLimit, !data.contains(10) else { throw Failure(message: "Invalid request size or framing") }
        try secureDirectory()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "Cannot create control socket") }
        defer { close(fd) }
        configure(fd)
        var addr = address()
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let connectError = errno
            if (connectError == ENOENT || connectError == ECONNREFUSED),
               let id = Bundle.main.bundleIdentifier,
               NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .allSatisfy({ $0.processIdentifier == getpid() }) {
                throw Failure(message: "TinyHand is not running. Launch the compatible app first.", code: "not-running")
            }
            throw Failure(message: "Could not connect to TinyHand. Quit any other copies and try again.")
        }
        guard sameUser(fd) else { throw Failure(message: "Could not verify the TinyHand control peer") }
        try writeLine(fd, data: data)
        return try readLine(fd, limit: responseLimit, deadline: .now() + .seconds(2))
    }

    static func runCLI(_ arguments: [String]) -> Int32 {
        do {
            guard arguments.count == 1, let data = arguments[0].data(using: .utf8) else {
                throw Failure(message: "Usage: TinyHand --ctl '<JSON request>'")
            }
            let response = try request(data)
            FileHandle.standardOutput.write(response + Data([10]))
            let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
            return object?["ok"] as? Bool == true ? 0 : 1
        } catch {
            let response: [String: Any] = ["version": version, "ok": false,
                "error": ["code": (error as? Failure)?.code ?? "unavailable", "message": (error as? Failure)?.message ?? error.localizedDescription]]
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
            return 2
        }
    }
}

final class ControlServer {
    private var listener: Int32 = -1
    private var lock: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "app.tinyhand.control")

    func start(handler: @escaping (Data) -> Data) throws {
        try ControlTransport.secureDirectory()
        lock = open(ControlTransport.directory + "/server.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw ControlTransport.Failure(message: "Cannot open control lock") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock); lock = -1
            throw ControlTransport.Failure(message: "A TinyHand control server is already running")
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { stop(); throw ControlTransport.Failure(message: "Cannot create listener") }
        ControlTransport.configure(listener)
        unlink(ControlTransport.path)
        var addr = ControlTransport.address()
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(ControlTransport.path, 0o600) == 0, listen(listener, 8) == 0 else {
            stop(); throw ControlTransport.Failure(message: "Cannot bind control socket")
        }
        guard fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
            stop(); throw ControlTransport.Failure(message: "Cannot configure the control socket")
        }
        let fd = listener
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler {
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            defer { close(peer) }
            guard ControlTransport.sameUser(peer), fcntl(peer, F_SETFL, 0) == 0 else { return }
            ControlTransport.configure(peer)
            do {
                let deadline = DispatchTime.now() + .seconds(1)
                let request = try ControlTransport.readLine(peer, limit: ControlTransport.requestLimit, deadline: deadline)
                let response = try DispatchQueue.main.sync {
                    guard DispatchTime.now() < deadline else {
                        throw ControlTransport.Failure(message: "TinyHand was busy before the request could run")
                    }
                    return handler(request)
                }
                try ControlTransport.writeLine(peer, data: response)
            } catch { /* Invalid, oversized, or disconnected clients cannot execute a command. */ }
        }
        // Release ownership only once pending connection handling has completed.
        let lockFD = lock
        readSource.setCancelHandler {
            close(fd)
            unlink(ControlTransport.path)
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        source = readSource
        readSource.resume()
    }

    func stop() {
        if let source = source {
            source.cancel()
            self.source = nil
        } else {
            if listener >= 0 { close(listener) }
            if lock >= 0 { flock(lock, LOCK_UN); close(lock) }
        }
        listener = -1
        lock = -1
    }

    deinit { stop() }
}
