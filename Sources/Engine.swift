import Foundation

enum Queue: String, CaseIterable, Identifiable {
    case ricohBW = "ePrint-Ricoh-BW"
    case ricohColor = "ePrint-Ricoh-Color"
    case lexmarkBW = "ePrint-Lexmark-BW"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ricohBW: "Ricoh, Black & White"
        case .ricohColor: "Ricoh, Colour"
        case .lexmarkBW: "Lexmark, Black & White"
        }
    }
    var isColor: Bool { self == .ricohColor }
    var ppd: String {
        switch self {
        case .ricohBW: "RICOH Aficio MP 5002"
        case .ricohColor: "RICOH Aficio MP C4503"
        case .lexmarkBW: "MS810"
        }
    }
}

enum Sides: String, CaseIterable, Identifiable {
    case one = "one-sided"
    case long = "two-sided-long-edge"
    case short = "two-sided-short-edge"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .one: "One-Sided"
        case .long: "Two-Sided (Long Edge)"
        case .short: "Two-Sided (Short Edge)"
        }
    }
    var isDuplex: Bool { self != .one }
}

let paperSizes = ["Letter", "Legal", "A4", "A5", "A6", "B5", "Executive"]
let printServer = "dku-ep-ps2-pap1.oit.duke.edu"

/// An error with a plain-language title and explanation for the user.
struct PrintFailure: Error, Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PrintJob {
    var file: URL
    var title: String
    var netid: String
    var queue: Queue
    var copies: Int
    var sides: Sides
    var paper: String
    var pageRange: String?   // nil = all pages
}

enum Engine {
    static func validNetID(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil
    }

    static func offNetwork(_ e: NetError) -> PrintFailure {
        var msg = "Are you connected to the DKU network? Off campus, connect to the DKU VPN and try again."
        if case .unreachable = e {
            msg += "\n\nIf you are on the network, check that DKU ezPrint is allowed under System Settings > Privacy & Security > Local Network."
        }
        return PrintFailure(title: "Can't Connect to the DKU Print Service", message: msg)
    }

    /// Convert the PDF to the printer's PostScript, honouring duplex, paper size and page range.
    static func filter(_ job: PrintJob, into out: URL) throws {
        guard let ppd = Bundle.main.url(forResource: job.queue.ppd, withExtension: "ppd", subdirectory: "ppd") else {
            throw PrintFailure(title: "Printer Driver Missing", message: "The \(job.queue.rawValue) driver is not bundled with this copy of the app. Reinstall DKU ezPrint.")
        }
        var args = ["-m", "application/vnd.cups-postscript", "-p", ppd.path, "-t", job.title]
        if job.copies > 1 { args += ["-n", String(job.copies)] }
        var opts = ["sides=\(job.sides.rawValue)", "media=\(job.paper)"]
        if let r = job.pageRange { opts.append("page-ranges=\(r)") }
        for o in opts { args += ["-o", o] }
        args.append(job.file.path)

        let errURL = out.appendingPathExtension("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/cupsfilter")
        p.arguments = args
        p.standardOutput = try FileHandle(forWritingTo: out)
        p.standardError = try FileHandle(forWritingTo: errURL)
        do { try p.run() } catch {
            throw PrintFailure(title: "Couldn't Prepare the Document", message: "macOS's print filter could not be started: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        if p.terminationStatus != 0 || (size ?? 0) == 0 {
            let log = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let tail = log.split(separator: "\n").filter { $0.hasPrefix("ERROR") }.suffix(2).joined(separator: "\n")
            throw PrintFailure(title: "Couldn't Prepare the Document",
                               message: "macOS could not convert this PDF for the printer." + (tail.isEmpty ? "" : "\n\n\(tail)"))
        }
    }

    static func send(_ job: PrintJob, progress: (String) -> Void) throws {
        guard validNetID(job.netid) else {
            throw PrintFailure(title: "Check Your NetID", message: "Enter your DKU NetID, using letters and numbers only.")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ezprint-\(UUID().uuidString).ps")
        defer { try? FileManager.default.removeItem(at: tmp) }

        progress("Preparing document…")
        try filter(job, into: tmp)
        let data = try Data(contentsOf: tmp)

        let hostname = Host.current().name ?? "mac"
        do {
            progress("Contacting the print service…")
            let descriptors = try Pharos.query(host: printServer, queue: job.queue.rawValue,
                                               netid: job.netid, jobName: job.title, hostname: hostname)
            let block = Pharos.block(hostname: hostname, netid: job.netid, jobName: job.title,
                                     descriptors: descriptors, copies: 1)
            progress("Sending…")
            try Pharos.lpdSend(host: printServer, queue: job.queue.rawValue, netid: job.netid,
                               jobName: job.title, hostname: hostname, payload: block + data)
        } catch let e as NetError {
            switch e {
            case _ where e.looksOffNetwork: throw offNetwork(e)
            case .closed: throw PrintFailure(title: "Connection Lost", message: "The print service closed the connection unexpectedly. Try again.")
            default: throw PrintFailure(title: "Couldn't Send the Job", message: "A network error occurred. \(e)")
            }
        } catch let e as Pharos.ProtocolError {
            throw PrintFailure(title: "The Print Service Rejected the Job", message: e.message)
        }
    }
}

/// Parse "1-4,7" into page numbers, or nil if malformed.
func parsePageRange(_ s: String, pageCount: Int) -> [Int]? {
    var pages: [Int] = []
    for part in s.split(separator: ",") {
        let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        switch bounds.count {
        case 1:
            guard let n = bounds[0], n >= 1, n <= pageCount else { return nil }
            pages.append(n)
        case 2:
            guard let a = bounds[0], let b = bounds[1], a >= 1, b >= a, b <= pageCount else { return nil }
            pages += Array(a...b)
        default: return nil
        }
    }
    return pages.isEmpty ? nil : pages
}
