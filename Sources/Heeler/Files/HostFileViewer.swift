import Foundation
import Observation
import QuickLook
import SwiftUI
import UIKit

/// Downloads one Host file into app-private temporary storage. Late-bound
/// against the Host's live session, exactly like `ImageStager`/`FileStager`,
/// so a Host edit mid-download is followed rather than captured.
typealias HostFileDownloader =
    @Sendable (String, AttachmentStageProgressReporter) async throws -> URL

/// One downloaded Host file, ready to preview.
struct HostFile: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The path as it was on the Host, for the title and for error copy.
    let remotePath: String
    /// The local copy, inside its own throwaway directory.
    let url: URL

    var name: String {
        let name = URL(fileURLWithPath: remotePath).lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }
}

/// The state behind "tap a path, look at the file".
///
/// The agent writes on the Host and the person reading is on an iPad, so the
/// only honest answer to a tapped path is to fetch the bytes and hand them to
/// Quick Look. The copy is temporary by construction: one directory per
/// download, deleted the moment the sheet closes, so nothing accumulates in
/// the app's container and a share is the only way a file persists.
@MainActor
@Observable
final class HostFileViewerStore {
    /// The file currently being previewed; drives the sheet.
    private(set) var file: HostFile?
    /// The path in flight, for the progress HUD's label.
    private(set) var downloadingPath: String?
    /// Set on failure; drives the alert.
    var errorMessage: String?
    private(set) var progress: Double?

    @ObservationIgnored private let download: HostFileDownloader
    @ObservationIgnored private var task: Task<Void, Never>?

    init(download: @escaping HostFileDownloader) {
        self.download = download
    }

    var isDownloading: Bool { downloadingPath != nil }

    /// Fetches `remotePath` and, once it lands, presents it. A second request
    /// replaces the first: the tap that started it is long gone.
    func open(_ remotePath: String) {
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        task?.cancel()
        discardDownloadedFile()
        downloadingPath = path
        progress = nil
        errorMessage = nil
        let download = self.download
        // Built outside the task: a reporter that captured the task's own
        // `self` would be a second capture of the same weak var.
        let reporter = AttachmentStageProgressReporter { [weak self] progress in
            await self?.report(progress)
        }
        task = Task { [weak self] in
            do {
                let url = try await download(path, reporter)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                self?.downloadingPath = nil
                self?.progress = nil
                self?.file = HostFile(remotePath: path, url: url)
            } catch is CancellationError {
                self?.downloadingPath = nil
                self?.progress = nil
            } catch {
                self?.downloadingPath = nil
                self?.progress = nil
                self?.errorMessage = Self.message(for: error)
            }
        }
    }

    func cancelDownload() {
        task?.cancel()
        task = nil
        downloadingPath = nil
        progress = nil
    }

    /// The sheet closed: the local copy goes with it. Anything the user
    /// wanted to keep left through the share sheet already.
    func dismiss() {
        discardDownloadedFile()
    }

    private func report(_ stage: AttachmentStageProgress) {
        guard stage.totalBytes > 0 else { return }
        progress = min(1, Double(stage.transferredBytes) / Double(stage.totalBytes))
    }

    private func discardDownloadedFile() {
        guard let file else { return }
        self.file = nil
        // The whole per-download directory, not just the file: it exists only
        // to hold this one copy.
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    private static func message(for error: any Error) -> String {
        if let downloadError = error as? HostFileDownloadError { return downloadError.message }
        if let transportError = error as? TransportError {
            return transportError.presentation.message
        }
        return HostFileDownloadError.transferFailed.message
    }

    /// A download the app was killed on top of leaves its directory behind;
    /// launch is the only moment nothing can be previewing one.
    static func cleanupRemnants() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelpie-downloads", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Quick Look, as a child view controller. Not `QLPreviewController`'s own
/// navigation chrome: presented as a plain child it draws none, which leaves
/// the sheet's own toolbar — Done, and the share button that puts the file
/// into Files — as the only controls.
struct HostFileQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController, previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

/// The preview sheet: the file, a way out, and a way to keep it.
struct HostFilePreviewSheet: View {
    let file: HostFile
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            HostFileQuickLookView(url: file.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done", action: onClose)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: file.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}

/// The "Open File on Host…" prompt: one path, typed.
struct HostFilePathPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let open: (String) -> Void
    @State private var path = ""

    func body(content: Content) -> some View {
        content.alert("Open File on Host", isPresented: $isPresented) {
            TextField("/path/to/file", text: $path)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { path = "" }
            Button("Open") {
                let requested = path
                path = ""
                open(requested)
            }
        } message: {
            Text("A full path on the Host, starting with / or ~/.")
        }
    }
}

/// The whole viewer as one modifier: the progress HUD while the bytes come
/// over, the Quick Look sheet when they land, and the alert when they do not.
struct HostFileViewerPresentation: ViewModifier {
    @Bindable var store: HostFileViewerStore

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .center) { downloadIndicator }
            .animation(.snappy, value: store.isDownloading)
            .sheet(
                item: Binding(
                    get: { store.file },
                    set: { if $0 == nil { store.dismiss() } })
            ) { file in
                HostFilePreviewSheet(file: file) { store.dismiss() }
            }
            .alert(
                "Cannot Open File",
                isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var downloadIndicator: some View {
        if let path = store.downloadingPath {
            VStack(spacing: 10) {
                if let progress = store.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 160)
                } else {
                    ProgressView()
                }
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Cancel") { store.cancelDownload() }
                    .font(.footnote)
            }
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .transition(.opacity)
            .accessibilityLabel("Downloading \(path) from the Host")
        }
    }
}

extension View {
    func hostFileViewer(_ store: HostFileViewerStore) -> some View {
        modifier(HostFileViewerPresentation(store: store))
    }

    func hostFilePathPrompt(
        isPresented: Binding<Bool>, open: @escaping (String) -> Void
    ) -> some View {
        modifier(HostFilePathPrompt(isPresented: isPresented, open: open))
    }
}
