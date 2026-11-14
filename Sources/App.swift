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
        guard v.document !== document else { return }
        // Stay on the same sheet when the layout is re-rendered.
        let index = v.currentPage.flatMap { v.document?.index(for: $0) } ?? 0
        v.document = document
        if let document, index > 0, let page = document.page(at: min(index, document.pageCount - 1)) {
            v.go(to: page)
        }
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
    @AppStorage("perSide") private var perSide = 1
    @AppStorage("booklet") private var booklet = false

    @State private var title = ""
    @State private var dropTargeted = false
    @State private var laidOut: PDFDocument?
    @State private var rendering = false

    private var selectedQueue: Queue { Queue(rawValue: queue) ?? .ricohBW }
    private var selectedSides: Sides { Sides(rawValue: sides) ?? .long }
    private var pageCount: Int { model.document?.pageCount ?? 0 }

    /// The pages that will print, or nil if the range is malformed.
    private var pages: [Int]? {
        guard pageCount > 0 else { return [] }
        return allPages ? Array(1...pageCount) : parsePageRange(pageRange, pageCount: pageCount)
    }

    /// The job as set up in the sidebar, or nil when there is nothing to print.
    private var job: PrintJob? {
        guard let url = model.url, let pages, !pages.isEmpty else { return nil }
        return PrintJob(file: url,
                        title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                        netid: netid.trimmingCharacters(in: .whitespaces),
                        queue: selectedQueue, copies: copies, sides: selectedSides, paper: paper,
                        pages: pages, perSide: perSide, booklet: booklet)
    }

    /// One copy of the job, minus the fields that don't change what prints, so typing
    /// a NetID or job name doesn't re-render the preview.
    private var previewJob: PrintJob? {
        guard var j = job else { return nil }
        j.title = ""; j.netid = ""; j.copies = 1; j.sides = .one
        return j
    }

    /// Pricing from it.dukekunshan.edu.cn/eprint-information: RMB 3.00 per colour
    /// side, RMB 0.30 per black & white side, and double-sided costs half.
    private let pricingPage = URL(string: "https://it.dukekunshan.edu.cn/eprint-information/")!

    private func cost(_ job: PrintJob, sidesPerCopy: Int) -> Decimal {
        let rate: Decimal = job.queue.isColor ? 3.00 : 0.30
        let factor: Decimal = job.effectiveSides.isDuplex ? 0.5 : 1
        return Decimal(sidesPerCopy * job.copies) * rate * factor
    }

    private var canPrint: Bool {
        job != nil && !model.isPrinting && Engine.validNetID(netid)
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
                } else if let laidOut {
                    PDFPreview(document: laidOut)
                        .overlay(alignment: .topTrailing) {
                            if rendering { ProgressView().controlSize(.small).padding(10) }
                        }
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            .task(id: previewJob) {
                guard let job = previewJob else { laidOut = nil; return }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                rendering = true
                let data = await Task.detached(priority: .userInitiated) { try? Engine.render(job) }.value
                guard !Task.isCancelled else { return }
                rendering = false
                laidOut = data.flatMap { PDFDocument(data: $0) }
            }

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
        .onChange(of: model.url) { _, new in
            title = new?.deletingPathExtension().lastPathComponent ?? ""
            laidOut = nil
        }
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
                if booklet && perSide == 2 {
                    LabeledContent("Sides", value: Sides.short.label)
                } else {
                    Picker("Sides", selection: $sides) {
                        ForEach(Sides.allCases) { Text($0.label).tag($0.rawValue) }
                    }
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
                Picker("Pages per Side", selection: $perSide) {
                    ForEach([1, 2, 4], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                if perSide == 2 {
                    Toggle("Booklet", isOn: $booklet)
                    if booklet {
                        Text("Prints two-sided. Fold the stack in half to read it as a booklet.")
                            .font(.caption).foregroundStyle(.secondary)
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
            if let job {
                let sides = Engine.impose(job).count
                let sheets = (job.effectiveSides.isDuplex ? (sides + 1) / 2 : sides) * copies
                Text("\(job.pages.count) \(job.pages.count == 1 ? "page" : "pages") · \(sheets) \(sheets == 1 ? "sheet" : "sheets") · \(paper) · \(selectedQueue.isColor ? "Colour" : "Black & White")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if model.isPrinting {
                    ProgressView().controlSize(.small)
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                } else if let job {
                    Text(cost(job, sidesPerCopy: Engine.impose(job).count).formatted(.currency(code: "CNY")))
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
        guard let job else { return }
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
