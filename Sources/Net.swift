import Foundation
import Darwin

/// Why a connection to the print service failed, in terms the UI can explain.
enum NetError: Error {
    case unresolved(String)
    case timedOut
    case refused
    case unreachable
    case closed
    case other(String)

    /// True when the likely cause is "you are not on the DKU network".
    var looksOffNetwork: Bool {
        switch self {
        case .unresolved, .timedOut, .refused, .unreachable: return true
        default: return false
        }
    }
}

/// A minimal blocking TCP client with a connect timeout.
final class TCP {
    private var fd: Int32 = -1

    init(host: String, port: UInt16, timeout: Double) throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
            throw NetError.unresolved(host)
        }
        defer { freeaddrinfo(res) }

        fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { throw NetError.other(String(cString: strerror(errno))) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if rc != 0 && errno != EINPROGRESS { throw map(errno) }
        if rc != 0 {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(timeout * 1000))
            if n == 0 { close(); throw NetError.timedOut }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { close(); throw map(err) }
        }
        _ = fcntl(fd, F_SETFL, flags)

        var tv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close() }

    private func map(_ e: Int32) -> NetError {
        switch e {
        case ECONNREFUSED: return .refused
        case ETIMEDOUT: return .timedOut
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN: return .unreachable
        default: return .other(String(cString: strerror(e)))
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { throw n == 0 ? NetError.closed : map(errno) }
                off += n
            }
        }
    }

    func recv(exactly n: Int) throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < n {
            let got = Darwin.recv(fd, &buf, min(buf.count, n - out.count), 0)
            if got == 0 { throw NetError.closed }
            if got < 0 { throw errno == EAGAIN ? NetError.timedOut : map(errno) }
            out.append(contentsOf: buf[0..<got])
        }
        return out
    }
}

/// The server's dotted-quad address, which the Pharos client sends as its "device name".
func resolveIPv4(_ host: String) -> String {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let info = res else { return host }
    defer { freeaddrinfo(res) }
    var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf)
}
