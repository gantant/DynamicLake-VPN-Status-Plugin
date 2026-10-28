import Darwin
import Foundation

public let DynamicLakeMaxFrameSize = 64 * 1024
public let DynamicLakeSendRetryDelayUs: UInt32 = 10_000
/// Bounds how long `sendAll` waits on a full socket buffer before failing, so a
/// wedged DynamicLake feeds the plugin's reconnect path instead of hanging it.
public let DynamicLakeSendMaxRetries = 100

/// User agent for every HTTPS lookup the plugin makes (exit country, Proton exit
/// identity). One constant for all of them, kept in sync with the version in
/// `plugin.json`; a per-file copy is how the Proton lookups once identified as
/// 1.1.7 in a 1.3.x build. Lives here because this file is compiled into the
/// plugin and into every test target that performs lookups.
public let pluginUserAgent = "VPNStatus-DynamicLake/1.4.0"

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
    /// Set when the host closes its end. The plugin cannot recover by reading
    /// (there is nothing left to read) and reconnects instead.
    public private(set) var isClosed = false

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit { close() }

    /// The socket's file descriptor, for a dispatch read source. -1 when
    /// disconnected.
    public var descriptor: Int32 { fileDescriptor }

    public func connect() throws {
        // Never leak the previous descriptor, and never carry a partial frame
        // from the old session into the new one.
        close()
        isClosed = false
        readBuffer.removeAll()

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DynamicLakeSocketError.socket("socket failed") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw DynamicLakeSocketError.socket("socket path too long")
        }

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
        guard result == 0 else {
            // A throw used to leave this descriptor open for the life of the
            // process; every failed reconnect leaked one.
            Darwin.close(fd)
            throw DynamicLakeSocketError.socket("connect failed")
        }
        fileDescriptor = fd

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

    /// Every complete frame that has arrived, leaving a partial frame buffered.
    /// Sets `isClosed` when the host has gone away.
    public func receiveAvailable() -> [[String: Any]] {
        guard fileDescriptor >= 0 else { return [] }
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let cap = tmp.count
            let count = tmp.withUnsafeMutableBytes { p in
                Darwin.recv(fileDescriptor, p.baseAddress!, cap, 0)
            }
            if count > 0 { readBuffer.append(tmp, count: count); continue }
            if count == 0 {
                // Orderly shutdown: nothing more will ever arrive.
                isClosed = true
                break
            }
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

/// A doorbell that wakes the plugin's main-queue work from any thread.
///
/// Status sources (NetworkExtension notifications, the path monitor, sleep and
/// wake, resolver completions) all fire on their own queues. They cannot touch
/// the plugin's state directly, and the plugin must not poll to notice them, so
/// each one writes a byte here; a read source on the main queue wakes and
/// re-renders. One byte is deliberate — the reader only needs "something
/// changed", and a full pipe already means a wake is pending, so `signal` never
/// blocks.
public final class EventSignal {
    public let descriptor: Int32
    private let writeDescriptor: Int32

    public init?() {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return nil }
        descriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        for fd in descriptors {
            let flags = Darwin.fcntl(fd, F_GETFL, 0)
            if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(writeDescriptor)
    }

    /// Wakes the reader. Safe from any thread; never blocks.
    public func signal() {
        var byte: UInt8 = 1
        _ = Darwin.write(writeDescriptor, &byte, 1)
    }

    /// Empties the pipe. Only the fact that it fired matters.
    public func drain() {
        var buffer = [UInt8](repeating: 0, count: 64)
        while Darwin.read(descriptor, &buffer, buffer.count) > 0 {}
    }
}
