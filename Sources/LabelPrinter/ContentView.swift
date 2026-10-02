import SwiftUI

struct ContentView: View {
    @StateObject private var printer = PrinterManager()

    @State private var showImporter = false
    @State private var fileURL: URL?
    @State private var job: LabelJob?
    @State private var isRendering = false
    @State private var message: String?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            statusRow

            if printer.isConnected || printer.isPrinting {
                fileSection
            } else {
                Button("Check Again") { printer.checkForPrinter() }
                    .disabled(printer.state == .searching || printer.state == .starting)
            }

            if let summary = printer.lastTransferSummary, !printer.isPrinting {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = message ?? printer.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(width: 360)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !printer.isPrinting else { return false }
            load(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onReceive(OpenedFiles.shared.$pending) { url in
            guard let url, !printer.isPrinting else { return }
            OpenedFiles.shared.pending = nil
            load(url)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: LabelRenderer.allowedTypes) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    // MARK: - Sections

    private var statusRow: some View {
        HStack(spacing: 8) {
            switch printer.state {
            case .starting, .searching:
                ProgressView().controlSize(.small)
                Text("Looking for printer…")
            case .bluetoothOff:
                Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.orange)
                Text("Bluetooth is off or not allowed")
            case .notFound:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("Printer not found")
            case .connected(let name):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected to \(name)")
            case .printing(let name, _):
                Image(systemName: "printer.fill").foregroundStyle(.blue)
                Text("Printing on \(name)…")
            }
        }
        .font(.headline)
    }

    private var fileSection: some View {
        VStack(spacing: 12) {
            if let preview = job?.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 240)
                    .border(.separator)
            }

            if let fileURL {
                Text(fileSummary(fileURL))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if case .printing(_, let progress) = printer.state {
                ProgressView(value: progress)
            }

            HStack {
                Button("Choose File…") { showImporter = true }
                Button("Print") { printLabel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job == nil)
            }
            .disabled(printer.isPrinting || isRendering)

            if fileURL == nil {
                Text("Or drag a PDF or image here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func fileSummary(_ url: URL) -> String {
        guard let job, job.pageCount > 1 else { return url.lastPathComponent }
        return "\(url.lastPathComponent) — \(job.pageCount) labels"
    }

    private func load(_ url: URL) {
        fileURL = url
        job = nil
        message = nil
        isRendering = true

        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let result = Result { try LabelRenderer.makeJob(from: url) }
            await MainActor.run {
                isRendering = false
                switch result {
                case .success(let newJob): job = newJob
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
    }

    private func printLabel() {
        guard let job else { return }
        message = nil
        printer.send(job.data) { error in
            if let error { message = error.localizedDescription }
        }
    }
}
