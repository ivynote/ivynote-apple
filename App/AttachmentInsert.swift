import IvynoteKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Adds files to the open note (guide 7.1): uploads each one, or queues it
/// when offline, and writes its reference into the body on a line of its own.
@MainActor
@Observable
final class AttachmentInserter {
    /// Files being uploaded, for the spinner beside the title.
    private(set) var busy = 0
    /// The last message worth showing (queued offline, refused).
    var notice: String?

    struct File {
        let name: String
        let mime: String
        let data: Data
    }

    func add(_ files: [File], to noteID: String, engine: SyncEngine, host: EditorHost) {
        guard !files.isEmpty else { return }
        busy += files.count
        Task {
            // One after another, so they land in the order they were picked.
            for f in files {
                defer { busy -= 1 }
                do {
                    let added = try await engine.addFile(f.data, name: f.name, mime: f.mime)
                    place(added, in: noteID, engine: engine, host: host)
                    if added.local && !engine.isLocal { notice = "「\(added.name)」已保存在本机，联网后自动上传" }
                } catch {
                    notice = "「\(f.name)」上传失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// At the cursor if the note is still open; otherwise at its end.
    private func place(_ file: AddedFile, in noteID: String, engine: SyncEngine, host: EditorHost) {
        if host.noteID == noteID {
            host.insertFile(file)
        } else if let note = engine.notes[noteID] {
            let sep = note.body.isEmpty || note.body.hasSuffix("\n") ? "" : "\n"
            engine.updateNote(noteID, .init(body: note.body + sep + file.markdown + "\n"))
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
        Menu("插入附件", systemImage: "paperclip") {
            Button("照片或视频", systemImage: "photo.on.rectangle") { pickers.photos = true }
            if AttachmentPickerState.cameraAvailable {
                Button("拍照", systemImage: "camera") { pickers.camera = true }
            }
            Button("文件", systemImage: "doc") { pickers.files = true }
        }
        .help("插入图片或文件")
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
