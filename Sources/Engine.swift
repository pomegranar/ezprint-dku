import Foundation
import PDFKit
import Quartz

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

struct PrintJob: Equatable, Sendable {
    var file: URL
    var title: String
    var netid: String
    var queue: Queue
    var copies: Int
    var sides: Sides
    var paper: String
    var pages: [Int]         // 1-based, in print order
    var perSide = 1          // 1, 2 or 4
    var booklet = false      // only with 2 per side

    var isBooklet: Bool { booklet && perSide == 2 }
    /// Booklets must flip on the short edge: the two-up sides are landscape on portrait paper.
    var effectiveSides: Sides { isBooklet ? .short : sides }
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

    /// Paper size and printable area (points) for a PPD page size name.
    static func paper(_ name: String, ppd: URL) -> (size: CGSize, printable: CGRect)? {
        guard let text = try? String(contentsOf: ppd, encoding: .isoLatin1) else { return nil }
        func values(_ key: String) -> [CGFloat]? {
            for line in text.split(separator: "\n") where line.hasPrefix("*\(key) \(name)/") || line.hasPrefix("*\(key) \(name):") {
                let quoted = line.split(separator: "\"")
                guard quoted.count > 1 else { continue }
                return quoted[1].split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
            }
            return nil
        }
        guard let d = values("PaperDimension"), d.count == 2 else { return nil }
        let a = values("ImageableArea") ?? []
        let printable = a.count == 4 ? CGRect(x: a[0], y: a[1], width: a[2] - a[0], height: a[3] - a[1])
                                     : CGRect(x: 0, y: 0, width: d[0], height: d[1])
        return (CGSize(width: d[0], height: d[1]), printable)
    }

    /// The document pages on each printed side of one copy, in print order; nil is a blank cell.
    /// A booklet pads to a multiple of four and orders pages so the stack folds in half:
    /// sheet i carries [last - 2i, first + 2i] on the front and [first + 2i + 1, last - 2i - 1] on the back.
    static func impose(_ job: PrintJob) -> [[Int?]] {
        if job.isBooklet {
            var p: [Int?] = job.pages
            while p.count % 4 != 0 { p.append(nil) }
            let n = p.count
            var sides: [[Int?]] = []
            for i in 0..<n / 4 {
                let front: [Int?] = [p[n - 1 - 2 * i], p[2 * i]]
                let back: [Int?] = [p[2 * i + 1], p[n - 2 - 2 * i]]
                sides += [front, back]
            }
            return sides
        }
        return stride(from: 0, to: job.pages.count, by: job.perSide).map { i in
            (i..<i + job.perSide).map { $0 < job.pages.count ? job.pages[$0] : nil }
        }
    }

    /// Where each cell of a side goes on the paper, in reading order. Two-up cells are read
    /// with the sheet turned to landscape (its top at the paper's left), so they are rotated
    /// and the reading-left cell sits at the bottom.
    static func cells(_ perSide: Int, in area: CGRect) -> [(rect: CGRect, turned: Bool)] {
        let gap: CGFloat = 8
        switch perSide {
        case 2:
            let h = (area.height - gap) / 2
            return [(CGRect(x: area.minX, y: area.minY, width: area.width, height: h), true),
                    (CGRect(x: area.minX, y: area.maxY - h, width: area.width, height: h), true)]
        case 4:
            let w = (area.width - gap) / 2, h = (area.height - gap) / 2
            let left = area.minX, right = area.maxX - w, top = area.maxY - h, bottom = area.minY
            return [(left, top), (right, top), (left, bottom), (right, bottom)].map {
                (CGRect(x: $0.0, y: $0.1, width: w, height: h), false)
            }
        default:
            return [(area, false)]
        }
    }

    /// Lay the chosen pages onto the paper: each page is centred and scaled up or down to fill
    /// its cell (the printable area, or a half or quarter of it), and turned if its orientation
    /// differs from the cell's. Copies are laid out collated here, each starting on a fresh sheet
    /// when printing two-sided. Black & white queues are converted to grayscale here, since the
    /// print server releases them to colour devices that would otherwise print colour as-is.
    static func layout(_ job: PrintJob, into consumer: CGDataConsumer) throws {
        let prepFailed = { (why: String) in PrintFailure(title: "Couldn't Prepare the Document", message: why) }
        let ppd = try ppd(for: job.queue)
        guard let doc = PDFDocument(url: job.file) else { throw prepFailed("The PDF could not be read.") }
        guard let paper = paper(job.paper, ppd: ppd) else {
            throw prepFailed("\(job.paper) paper is not supported by \(job.queue.label).")
        }
        var media = CGRect(origin: .zero, size: paper.size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw prepFailed("Could not create a temporary file.") }

        var gray: QuartzFilter?
        if !job.queue.isColor {
            guard let f = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Gray Tone.qfilter")),
                  f.apply(to: ctx) else {
                ctx.closePDF()
                throw prepFailed("macOS's Gray Tone filter is missing, so the document can't be converted to black and white.")
            }
            gray = f
        }

        var sides = impose(job)
        if job.effectiveSides.isDuplex && sides.count % 2 == 1 { sides.append([]) }
        let all = (0..<job.copies).flatMap { _ in sides }.dropLast(sides.last?.isEmpty == true ? 1 : 0)
        let cells = cells(job.perSide, in: paper.printable)

        for side in all {
            ctx.beginPDFPage(nil)
            for (cell, n) in zip(cells, side) {
                guard let n, let page = doc.page(at: n - 1) else { continue }
                let box = page.bounds(for: .cropBox)
                var w = box.width, h = box.height
                if page.rotation % 180 != 0 { swap(&w, &h) }
                var cw = cell.rect.width, ch = cell.rect.height

                ctx.saveGState()
                ctx.translateBy(x: cell.rect.midX, y: cell.rect.midY)
                if cell.turned { ctx.rotate(by: .pi / 2); swap(&cw, &ch) }
                let turn = (w > h) != (cw > ch)
                if turn { ctx.rotate(by: .pi / 2) }
                let scale = turn ? min(cw / h, ch / w) : min(cw / w, ch / h)
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -w / 2, y: -h / 2)
                page.draw(with: .cropBox, to: ctx)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        gray?.remove(from: ctx)
        ctx.closePDF()
    }

    /// The laid-out document as PDF data, for the preview.
    static func render(_ job: PrintJob) throws -> Data {
        let data = NSMutableData()
        try layout(job, into: CGDataConsumer(data: data as CFMutableData)!)
        return data as Data
    }

    static func ppd(for queue: Queue) throws -> URL {
        guard let url = Bundle.main.url(forResource: queue.ppd, withExtension: "ppd", subdirectory: "ppd") else {
            throw PrintFailure(title: "Printer Driver Missing", message: "The \(queue.rawValue) driver is not bundled with this copy of the app. Reinstall DKU ezPrint.")
        }
        return url
    }

    /// Convert the PDF to the printer's PostScript, honouring paper size, layout, colour and duplex.
    static func filter(_ job: PrintJob, into out: URL) throws {
        let ppd = try ppd(for: job.queue)
        let laidOut = out.deletingPathExtension().appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: laidOut) }
        do {   // scoped so the consumer is released, and the file closed, before cupsfilter reads it
            guard let consumer = CGDataConsumer(url: laidOut as CFURL) else {
                throw PrintFailure(title: "Couldn't Prepare the Document", message: "Could not create a temporary file.")
            }
            try layout(job, into: consumer)
        }

        var args = ["-m", "application/vnd.cups-postscript", "-p", ppd.path, "-t", job.title]
        for o in ["sides=\(job.effectiveSides.rawValue)", "media=\(job.paper)"] { args += ["-o", o] }
        args.append(laidOut.path)

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
        if p.terminationStatus != 0 || size == 0 {
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
