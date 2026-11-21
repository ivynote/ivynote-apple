import IvynoteKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Adds files to the open note (guide 7.1): copies each one into the local
/// attachment library right away, inserts its reference without waiting for
/// the network, and lets `SyncEngine` upload and normalize links in the background.
@MainActor
@Observable
final class AttachmentInserter {
    /// Files being staged locally, for the spinner beside the title.
    private(set) var busy = 0
    /// The last message worth showing (offline queued, error).
    var notice: String?

    struct File {
        let name: String
        let mime: String
        let data: Data
    }

    func add(_ files: [File], to noteID: String, engine: SyncEngine, host: EditorHost) {
        guard !files.isEmpty else { return }
        busy += files.count
        defer { busy -= files.count }
        var staged: [AddedFile] = []
        for f in files {
            do {
                let added = try engine.addFileLocal(f.data, name: f.name, mime: f.mime)
                staged.append(added)
            } catch {
                notice = L10n.s.uploadFailed(f.name, error.localizedDescription)
            }
        }
        guard !staged.isEmpty else { return }
        place(staged, in: noteID, engine: engine, host: host)
        if engine.state.status == .offline && !engine.isLocal {
            notice = staged.count == 1 ? L10n.s.savedLocally(staged[0].name) : L10n.s.savedLocallyUploadLater
        }
    }

    /// At the latest cursor position if the note is still open; otherwise at its end.
    private func place(_ files: [AddedFile], in noteID: String, engine: SyncEngine, host: EditorHost) {
        if host.noteID == noteID {
            host.insertFiles(files)
        } else if let note = engine.notes[noteID] {
            let sep = note.body.isEmpty || note.body.hasSuffix("\n") ? "" : "\n"
            let block = files.map(\.markdown).joined(separator: "\n") + "\n"
            engine.updateNote(noteID, .init(body: note.body + sep + block))
        }
    }

    static func mime(for type: UTType?) -> String {
        type?.preferredMIMEType ?? "application/octet-stream"
    }

    /// A file picked in the Files app (or Finder), read while access lasts.
    static func readFile(_ url: URL) -> File? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        return File(name: url.lastPathComponent, mime: mime(for: type), data: data)
    }

    /// A photo or video from the library; it comes without a usable name.
    static func readPhoto(_ item: PhotosPickerItem) async -> File? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first { $0.conforms(to: .image) || $0.conforms(to: .movie) } ?? item.supportedContentTypes.first
        let mime = mime(for: type)
        let ext = type?.preferredFilenameExtension ?? "bin"
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let prefix = type?.conforms(to: .movie) == true ? "video" : "image"
        return File(name: "\(prefix)-\(stamp).\(ext)", mime: mime, data: data)
    }
}

/// The ways to pick a file, shown by `AttachmentPickers` when their flag is set.
struct AttachmentPickerState {
    var photos = false
    var files = false
    var camera = false

    @MainActor
    static var cameraAvailable: Bool {
        #if os(iOS)
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #else
        false
        #endif
    }
}

/// Photo library, files and (on iPhone and iPad) the camera.
struct AttachmentPickers: ViewModifier {
    @Binding var state: AttachmentPickerState
    let onPick: ([AttachmentInserter.File]) -> Void

    @State private var items: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $state.photos, selection: $items, maxSelectionCount: 20,
                          matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
            .onChange(of: items) { _, picked in
                guard !picked.isEmpty else { return }
                items = []
                Task {
                    var files: [AttachmentInserter.File] = []
                    for item in picked {
                        if let f = await AttachmentInserter.readPhoto(item) { files.append(f) }
                    }
                    onPick(files)
                }
            }
            .fileImporter(isPresented: $state.files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                onPick(urls.compactMap { AttachmentInserter.readFile($0) })
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $state.camera) {
                CameraPicker { image in
                    state.camera = false
                    guard let image, let data = image.jpegData(compressionQuality: 0.9) else { return }
                    onPick([AttachmentInserter.File(name: EditorHost.DroppedFile.pastedName(mime: "image/jpeg"), mime: "image/jpeg", data: data)])
                }
                .ignoresSafeArea()
            }
            #endif
    }
}

/// The insert menu of the note's toolbar.
struct InsertMenu: View {
    @Binding var pickers: AttachmentPickerState

    var body: some View {
        Menu(L.insertAttachment, systemImage: "paperclip") {
            Button(L.photoOrVideo, systemImage: "photo.on.rectangle") { pickers.photos = true }
            if AttachmentPickerState.cameraAvailable {
                Button(L.camera, systemImage: "camera") { pickers.camera = true }
            }
            Button(L.file, systemImage: "doc") { pickers.files = true }
        }
        .help(L.insertAttachmentHelp)
    }
}

#if os(iOS)
/// The system camera, for 拍照 (guide 3.2).
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void
        init(_ onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDone(nil)
        }
    }
}
#endif
