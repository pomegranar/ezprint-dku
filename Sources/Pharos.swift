import Foundation

/// Pharos Uniprint "popup" protocol: ask the server what a queue wants to know
/// (port 28203), then wrap the print data in a popup block and send it over LPD
/// (port 515). See the dku-eprint-linux docs/PROTOCOL.md for the wire formats.
enum Pharos {
    static let signature = Data("PSPOPUP".utf8)
    static let clientVersion = "1003"
    static let sep: UInt8 = 0x0c
    static let headerLen = 19

    struct ProtocolError: Error { let message: String }

    struct Descriptor {
        var name: String
        var type: String
        var hierarchy: String
        var answer = ""
    }

    // MARK: popup server

    final class Client {
        let tcp: TCP
        var version = clientVersion
        init(host: String) throws { tcp = try TCP(host: host, port: 28203, timeout: 10) }

        func request(_ fields: [String]) throws -> [String] {
            var body = Data()
            for f in fields { body.append(Data(f.utf8)); body.append(sep) }
            var pkt = signature
            pkt.append(Data(version.utf8)); pkt.append(sep)
            pkt.append(Data(String(format: "%06d", headerLen + body.count).utf8)); pkt.append(sep)
            pkt.append(body)
            try tcp.send(pkt)

            let header = try tcp.recv(exactly: headerLen)
            guard header.starts(with: signature) else { throw ProtocolError(message: "unexpected reply from print server") }
            version = String(decoding: header[7..<11], as: UTF8.self)
            let parts = header.split(separator: sep, omittingEmptySubsequences: false)
            guard parts.count > 1, let total = Int(String(decoding: parts[1], as: UTF8.self)), total >= headerLen else {
                throw ProtocolError(message: "malformed reply from print server")
            }
            let rest = try tcp.recv(exactly: total - headerLen)
            var items = rest.split(separator: sep, omittingEmptySubsequences: false)
            if let last = items.last, last.isEmpty { items.removeLast() }
            return items.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// The questions a queue wants answered, each answered with the NetID.
    static func query(host: String, queue: String, netid: String, jobName: String,
                      hostname: String) throws -> [Descriptor] {
        let c = try Client(host: host)
        let r = try c.request(["INITNEWJOB", hostname, resolveIPv4(host), queue, netid, jobName])
        guard r.count >= 2 else { throw ProtocolError(message: "short reply from print server") }
        if r[1] == "NOQUEUE" { throw ProtocolError(message: "The print server has no queue named \(queue).") }
        var out: [Descriptor] = []
        while true {
            let d = try c.request(["GETNEXTDESCRIPTOR", r[1]])
            if d.count < 13 { break }
            var desc = Descriptor(name: d[1], type: d[4], hierarchy: d[12])
            if desc.type != "Guest" { desc.answer = netid }
            out.append(desc)
        }
        return out
    }

    // MARK: popup block

    static let rc4Key: [UInt8] = [0x42, 0x95, 0xf2, 0xa7, 0x68, 0x05, 0x11, 0xb4,
                                  0xc3, 0x74, 0x39, 0xe1, 0xd2, 0x66, 0x57, 0x94]

    static func rc4(_ key: [UInt8], _ data: Data) -> Data {
        var s = (0..<256).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(key[i % key.count]) + Int(s[i])) & 0xff
            s.swapAt(i, j)
        }
        var out = Data(count: data.count)
        var i = 0; j = 0
        for (n, byte) in data.enumerated() {
            i = (i + 1) & 0xff
            j = (j + Int(s[i])) & 0xff
            s.swapAt(i, j)
            out[n] = byte ^ s[(Int(s[i]) + Int(s[j])) & 0xff]
        }
        return out
    }

    private static func ascii(_ s: String) -> Data {
        Data(s.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") })
    }
    private static func cstr(_ s: String) -> Data { ascii(s) + Data([0]) }

    static func block(hostname: String, netid: String, jobName: String,
                      descriptors: [Descriptor], copies: Int) -> Data {
        var s1 = cstr(hostname)
        s1.append(cstr(netid)); s1.append(cstr(jobName)); s1.append(cstr("0"))

        var s23 = Data()
        for d in descriptors {
            if d.type == "Guest" && d.answer.isEmpty { continue }
            if d.hierarchy.isEmpty {
                s23 += ascii(d.name) + Data([0])
            } else {
                s23 += ascii("CC_Static") + Data([0]) + ascii(d.hierarchy) + Data([0x0d])
            }
            if !d.answer.isEmpty { s23 += ascii(d.answer) }
            s23 += Data([0])
        }

        var xml = "<AppTrackerJob>\n<ProcessExecutable>DKU ezPrint</ProcessExecutable>\n"
        xml += "<AppTrackerPages>0</AppTrackerPages>\n"
        xml += "<AppTrackerCopies>\(copies)</AppTrackerCopies>\n</AppTrackerJob>"
        let s4 = ascii(xml)
        var body = s1
        body.append(s23)
        body.append(s4)

        var head = Data([0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7])
        head.append(ascii(String(format: "%07d", body.count)))
        head.append(0)
        head.append(ascii("154"))
        head.append(0)
        head.append(ascii(String(format: "%05d", s1.count + s23.count)))
        head.append(0)
        head.append(ascii(String(format: "%05d", s4.count)))
        head.append(0)
        return head + rc4(rc4Key, body)
    }

    // MARK: LPD (RFC 1179)

    static func lpdSend(host: String, queue: String, netid: String, jobName: String,
                        hostname: String, payload: Data) throws {
        let tcp = try TCP(host: host, port: 515, timeout: 10)
        let host31 = String(hostname.prefix(31))
        let id = String(format: "%03d", Int.random(in: 1...999))

        func command(_ data: Data) throws {
            try tcp.send(data)
            guard try tcp.recv(exactly: 1) == Data([0]) else {
                throw ProtocolError(message: "The print server refused the job.")
            }
        }
        try command(Data([2]) + ascii(queue) + Data("\n".utf8))

        let control = ascii("H\(host31)\nP\(String(netid.prefix(31)))\nJ\(jobName)\n"
                            + "ldfA\(id)\(host31)\nUdfA\(id)\(host31)\nN\(jobName)\n")
        try command(Data([2]) + ascii("\(control.count) cfA\(id)\(host31)\n"))
        try tcp.send(control + Data([0]))
        guard try tcp.recv(exactly: 1) == Data([0]) else {
            throw ProtocolError(message: "The print server rejected the job's control file.")
        }

        try command(Data([3]) + ascii("\(payload.count) dfA\(id)\(host31)\n"))
        try tcp.send(payload + Data([0]))
        guard try tcp.recv(exactly: 1) == Data([0]) else {
            throw ProtocolError(message: "The print server rejected the document. Check that your NetID is correct.")
        }
    }
}
