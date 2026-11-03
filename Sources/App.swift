import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@main
struct DKUezPrintApp: App {
    @State private var model = PrintModel()

    var body: some Scene {
        Window("DKU ezPrint", id: "main") {
            ContentView(model: model)
                .onOpenURL { model.open($0) }
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.showImporter = true }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor @Observable
final class PrintModel {
    var url: URL?
    var document: PDFDocument?
    var showImporter = false
    var isPrinting = false
    var status = ""
    var failure: PrintFailure?
    var sent = false

    func clear() {
        url = nil
        document = nil
    }

    func open(_ url: URL) {
        guard let doc = PDFDocument(url: url) else {
            failure = PrintFailure(title: "Can't Open This File", message: "\(url.lastPathComponent) is not a PDF that DKU ezPrint can read.")
            return
        }
        if doc.isLocked {
            failure = PrintFailure(title: "Password-Protected PDF", message: "\(url.lastPathComponent) is locked. Remove the password in Preview, then open it again.")
            return
        }
        self.url = url
        document = doc
    }
}

struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument?
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document !== document { v.document = document }
    }
}

struct ContentView: View {
    @Bindable var model: PrintModel

    // Remembered between launches.
    @AppStorage("netid") private var netid = ""
    @AppStorage("queue") private var queue = Queue.ricohBW.rawValue
    @AppStorage("sides") private var sides = Sides.long.rawValue
    @AppStorage("paper") private var paper = "A4"
    @AppStorage("copies") private var copies = 1
    @AppStorage("allPages") private var allPages = true
    @AppStorage("pageRange") private var pageRange = ""

    @State private var title = ""
    @State private var dropTargeted = false

    private var selectedQueue: Queue { Queue(rawValue: queue) ?? .ricohBW }
    private var selectedSides: Sides { Sides(rawValue: sides) ?? .long }
    private var pageCount: Int { model.document?.pageCount ?? 0 }

    /// The pages that will print, or nil if the range is malformed.
    private var pages: [Int]? {
        guard pageCount > 0 else { return [] }
        return allPages ? Array(1...pageCount) : parsePageRange(pageRange, pageCount: pageCount)
    }

    private var preview: PDFDocument? {
        guard let doc = model.document, let pages else { return model.document }
        if allPages { return doc }
        let out = PDFDocument()
        for (i, n) in pages.enumerated() {
            if let page = doc.page(at: n - 1)?.copy() as? PDFPage { out.insert(page, at: i) }
        }
        return out
    }

    /// Pricing from it.dukekunshan.edu.cn/eprint-information: RMB 3.00 per colour
    /// side, RMB 0.30 per black & white side, and double-sided costs half.
    private let pricingPage = URL(string: "https://it.dukekunshan.edu.cn/eprint-information/")!

    private func cost(_ sidesPrinted: Int) -> Decimal {
        let rate: Decimal = selectedQueue.isColor ? 3.00 : 0.30
        let factor: Decimal = selectedSides.isDuplex ? 0.5 : 1
        return Decimal(sidesPrinted * copies) * rate * factor
    }

    private var canPrint: Bool {
        model.document != nil && !model.isPrinting && Engine.validNetID(netid) && (pages?.isEmpty == false)
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if model.document == nil {
                    ContentUnavailableView {
                        Label("No Document", systemImage: "doc")
                    } description: {
                        Text("Open a PDF, or drop one here.")
                    } actions: {
                        Button("Open…") { model.showImporter = true }
                    }
                } else {
                    PDFPreview(document: preview)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(spacing: 0) {
                settings
                Divider()
                footer
            }
            .frame(width: 320)
        }
        .frame(minHeight: 480)
        .navigationTitle(model.url?.lastPathComponent ?? "DKU ezPrint")
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            model.open(u); return true
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let u) = result { model.open(u) }
        }
        .onChange(of: model.url) { _, new in title = new?.deletingPathExtension().lastPathComponent ?? "" }
        .alert(item: $model.failure) { f in
            Alert(title: Text(f.title), message: Text(f.message), dismissButton: .default(Text("OK")))
        }
        .alert("Sent to ePrint", isPresented: $model.sent) {
            Button("OK") {}
        } message: {
            Text("Release it with your DKUCard at any ePrint station.")
        }
    }

    private var settings: some View {
        Form {
            Section("Document") {
                HStack {
                    Image(systemName: model.document == nil ? "doc" : "doc.richtext")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.url?.lastPathComponent ?? "No file chosen")
                            .lineLimit(1).truncationMode(.middle)
                        Text(model.document == nil ? "Drop a PDF here"
                             : "\(pageCount) \(pageCount == 1 ? "page" : "pages")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") { model.showImporter = true }
                    if model.document != nil {
                        Button { model.clear() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear the file")
                    }
                }
                .padding(.vertical, 2)
                .background(dropTargeted ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first else { return false }
                    model.open(u); return true
                } isTargeted: { dropTargeted = $0 }
            }
            Section("Account") {
                TextField("DKU NetID", text: $netid)
                    .autocorrectionDisabled()
            }
            Section("Printer") {
                Picker("Printer", selection: $queue) {
                    ForEach(Queue.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Paper Size", selection: $paper) {
                    ForEach(paperSizes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Sides", selection: $sides) {
                    ForEach(Sides.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Stepper("Copies: \(copies)", value: $copies, in: 1...99)
            }
            Section("Pages") {
                Picker("Print", selection: $allPages) {
                    Text("All Pages").tag(true)
                    Text("Range").tag(false)
                }
                if !allPages {
                    TextField("Pages", text: $pageRange, prompt: Text("1-4, 7"))
                    if pages == nil && pageCount > 0 {
                        Text("Enter pages between 1 and \(pageCount), like 1-4, 7.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Section("Job") {
                TextField("Name", text: $title, prompt: Text("Shown at the station"))
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.document != nil, let pages {
                let sheets = selectedSides.isDuplex ? (pages.count + 1) / 2 : pages.count
                Text("\(pages.count) \(pages.count == 1 ? "page" : "pages") · \(sheets * copies) \(sheets * copies == 1 ? "sheet" : "sheets") · \(paper) · \(selectedQueue.isColor ? "Colour" : "Black & White")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if model.isPrinting {
                    ProgressView().controlSize(.small)
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                } else if model.document != nil, let pages {
                    Text(cost(pages.count).formatted(.currency(code: "CNY")))
                        .monospacedDigit()
                    Button {
                        NSWorkspace.shared.open(pricingPage)
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("How printing is priced")
                }
                Spacer()
                Button("Print") { startPrint() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPrint)
            }
        }
        .padding()
    }

    private func startPrint() {
        guard let url = model.url, let pages else { return }
        let job = PrintJob(
            file: url,
            title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
            netid: netid.trimmingCharacters(in: .whitespaces),
            queue: selectedQueue, copies: copies, sides: selectedSides, paper: paper,
            pageRange: allPages ? nil : pageRange.replacingOccurrences(of: " ", with: ""))
        _ = pages
        model.isPrinting = true
        Task.detached {
            do {
                try Engine.send(job) { s in Task { @MainActor in model.status = s } }
                await MainActor.run { model.isPrinting = false; model.sent = true; model.clear() }
            } catch let f as PrintFailure {
                await MainActor.run { model.isPrinting = false; model.failure = f }
            } catch {
                await MainActor.run {
                    model.isPrinting = false
                    model.failure = PrintFailure(title: "Couldn't Print", message: error.localizedDescription)
                }
            }
        }
    }
}
