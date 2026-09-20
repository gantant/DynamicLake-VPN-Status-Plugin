import Darwin
import Foundation

public let DynamicLakeMaxFrameSize = 64 * 1024
public let DynamicLakePollIntervalUs: UInt32 = 50_000
public let DynamicLakeSendRetryDelayUs: UInt32 = 10_000
/// Bounds how long `sendAll` waits on a full socket buffer before failing, so a
/// wedged DynamicLake feeds the plugin's reconnect path instead of hanging it.
public let DynamicLakeSendMaxRetries = 100

public enum DynamicLakeSocketError: Error, CustomStringConvertible {
    case socketPathMissing(String)
    case socket(String)
    case frameTooLarge(Int)

    public var description: String {
        switch self {
        case .socketPathMissing(let key): return "\(key) is missing"
        case .socket(let m): return m
        case .frameTooLarge(let s): return "frame too large: \(s)"
        }
    }
}

public final class JSONSocketClient {
    public let socketPath: String
    private var fileDescriptor: Int32 = -1
    private var readBuffer = Data()

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit { close() }

    public func connect() throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DynamicLakeSocketError.socket("socket failed") }
        fileDescriptor = fd

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else { throw DynamicLakeSocketError.socket("socket path too long") }

        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { dest in
                    memset(dest, 0, maxPathLength)
                    strncpy(dest, source, maxPathLength - 1)
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw DynamicLakeSocketError.socket("connect failed") }

        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    public func close() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    public func send(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard data.count <= DynamicLakeMaxFrameSize else { throw DynamicLakeSocketError.frameTooLarge(data.count) }
        var frame = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(data)
        try sendAll(frame)
    }

    public func receiveAvailable() -> [[String: Any]] {
        guard fileDescriptor >= 0 else { return [] }
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let cap = tmp.count
            let count = tmp.withUnsafeMutableBytes { p in
                Darwin.recv(fileDescriptor, p.baseAddress!, cap, 0)
            }
            if count > 0 { readBuffer.append(tmp, count: count); continue }
            if count == 0 { break }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            break
        }
        var messages: [[String: Any]] = []
        while readBuffer.count >= 4 {
            let lenData = readBuffer.prefix(4)
            let length = lenData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if length > DynamicLakeMaxFrameSize { readBuffer.removeAll(); break }
            let total = Int(length) + 4
            guard readBuffer.count >= total else { break }
            let body = readBuffer.subdata(in: 4..<total)
            readBuffer.removeSubrange(0..<total)
            if let obj = try? JSONSerialization.jsonObject(with: body, options: []),
               let dict = obj as? [String: Any] {
                messages.append(dict)
            }
        }
        return messages
    }

    private func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            var retries = 0
            while sent < data.count {
                let r = Darwin.send(fileDescriptor, base.advanced(by: sent), data.count - sent, 0)
                if r > 0 { sent += r; retries = 0; continue }
                if r < 0 && errno == EINTR { continue }
                if r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    retries += 1
                    guard retries <= DynamicLakeSendMaxRetries else {
                        throw DynamicLakeSocketError.socket("send failed: socket buffer full after \(DynamicLakeSendMaxRetries) retries")
                    }
                    usleep(DynamicLakeSendRetryDelayUs)
                    continue
                }
                throw DynamicLakeSocketError.socket("send failed")
            }
        }
    }
}

public func runProcess(_ path: String, arguments: [String], timeout: TimeInterval = 5, log: ((String) -> Void)? = nil) -> (Data, Int32) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    if let log = log {
        log("run: \(path) \(arguments.joined(separator: " "))")
    }
    do {
        try proc.run()
    } catch {
        return (Data(), -1)
    }
    // Close the child's pipe ends on every path past a successful spawn —
    // including the timeout/kill path — so a throw-free run can never leak
    // descriptors into the poll loop.
    defer {
        outPipe.fileHandleForReading.closeFile()
        errPipe.fileHandleForReading.closeFile()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline {
        usleep(DynamicLakePollIntervalUs)
    }
    if proc.isRunning {
        // Graceful stop first; escalate to SIGKILL so a hung child (or a hung
        // readDataToEndOfFile on its pipes) can never stall the poll loop.
        proc.terminate()
        let killDeadline = Date().addingTimeInterval(0.5)
        while proc.isRunning && Date() < killDeadline {
            usleep(DynamicLakePollIntervalUs)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        proc.waitUntilExit()
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    _ = errPipe.fileHandleForReading.readDataToEndOfFile()
    return (data, proc.terminationStatus)
}
