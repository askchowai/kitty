import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import KittyCore

/// Browse the gateway's managed files (`/api/files`), preview with Quick Look, upload from Files.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    @State private var path: String? = nil
    @State private var listing: FilesListing?
    @State private var error: String?
    @State private var loading = false
    @State private var previewURL: URL?
    @State private var downloading: String?
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                if let l = listing {
                    Section {
                        Text(l.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Section {
                        if let parent = l.parent { Button { path = parent } label: { Label("Up", systemImage: "arrow.up.doc") } }
                        ForEach(l.entries) { e in
                            if e.isDirectory {
                                Button { path = e.path } label: { Label(e.name, systemImage: "folder") }
                            } else {
                                Button { Task { await open(e) } } label: {
                                    HStack {
                                        Label(e.name, systemImage: icon(for: e))
                                        Spacer()
                                        if downloading == e.path { ProgressView().controlSize(.small) }
                                        else if let s = e.size { Text(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                .contextMenu {
                                    Button { Task { await open(e) } } label: { Label("Preview", systemImage: "eye") }
                                    ShareLink(item: e.path) { Label("Copy path", systemImage: "doc.on.doc") }
                                }
                            }
                        }
                    }
                }
            }
            .overlay { if loading && listing == nil { ProgressView() } }
            .navigationTitle("Files")
            .tabRoot(.files)
            .background(InteractivePopEnabler())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { path = nil } label: { Label("Home", systemImage: "house") } }
                ToolbarItem(placement: .primaryAction) { Button { showImporter = true } label: { Label("Upload", systemImage: "square.and.arrow.up") } }
            }
            .refreshable { await load() }
            .task(id: path) { await load() }
            .task(id: model.runtime?.connection.id) { await load() }
            .quickLookPreview($previewURL)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { Task { await upload(urls) } }
            }
        }
    }

    private func icon(for e: FileEntry) -> String {
        let t = UTType(filenameExtension: (e.name as NSString).pathExtension)
        if t?.conforms(to: .image) == true { return "photo" }
        if t?.conforms(to: .movie) == true { return "video" }
        if t?.conforms(to: .audio) == true { return "waveform" }
        if t?.conforms(to: .pdf) == true { return "doc.richtext" }
        if t?.conforms(to: .sourceCode) == true || t?.conforms(to: .plainText) == true { return "doc.text" }
        return "doc"
    }

    private func load() async {
        guard let rt = model.runtime else { return }
        loading = true; defer { loading = false }
        do {
            var q: [URLQueryItem] = []
            if let path { q.append(URLQueryItem(name: "path", value: path)) }
            listing = try await rt.api.get("/api/files", query: q)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func open(_ e: FileEntry) async {
        guard let rt = model.runtime else { return }
        downloading = e.path; defer { downloading = nil }
        do { previewURL = try await rt.api.download("/api/files/download", query: [URLQueryItem(name: "path", value: e.path)]) }
        catch { self.error = error.localizedDescription }
    }

    private func upload(_ urls: [URL]) async {
        guard let rt = model.runtime, let dir = listing?.path else { return }
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: u) else { continue }
            let mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            do {
                let _: ManagedUploadResult = try await rt.api.sendMultipart("/api/files/upload-stream", fields: ["path": dir + "/" + u.lastPathComponent, "overwrite": "true"], fileField: "file", filename: u.lastPathComponent, fileData: data, mimeType: mime)
            } catch { self.error = error.localizedDescription }
        }
        await load()
    }
}
