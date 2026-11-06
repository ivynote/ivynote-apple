import IvynoteKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Fetches attachments outside the editor (media library, previews,
/// downloads) with the account's token in a header, through the editor's
/// cache. Files still waiting to be uploaded are read from this device.
@MainActor
@Observable
final class MediaLoader {
    @ObservationIgnored private let api: APIClient?
    @ObservationIgnored private weak var engine: SyncEngine?
    @ObservationIgnored private let images = NSCache<NSString, PlatformImage>()

    init(api: APIClient?, engine: SyncEngine) {
        self.api = api
        self.engine = engine
        images.countLimit = 300
    }

    func data(_ id: String, thumb: Bool = false) async throws -> Data {
        if let local = engine?.uploadFile(id) { return try Data(contentsOf: local.url) }
        guard let api else { throw APIError.unreachable(L10n.s.localNoServer) }
        let (data, response) = try await EditorSchemeHandler.mediaSession.data(for: api.rawRequest(id, thumb: thumb))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.server(status: http.statusCode, message: "")
        }
        return data
    }

    /// A thumbnail (long side 480) or the full image, kept in memory.
    func image(_ id: String, thumb: Bool = true) async -> PlatformImage? {
        let key = "\(id)|\(thumb)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let bytes = try? await self.data(id, thumb: thumb), let image = PlatformImage(data: bytes) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// The file under its own name in a temporary folder, for Quick Look,
    /// sharing and saving.
    func file(_ id: String, name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ivy-files/\(id)", directoryHint: .isDirectory)
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = dir.appending(path: clean.isEmpty ? id : clean)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let bytes = try await self.data(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        return url
    }
}

/// A square tile of an attachment: the thumbnail for images, an icon for
/// everything else.
struct AttachmentThumbnail: View {
    @Environment(MediaLoader.self) private var loader
    let id: String
    let kind: String
    var hasThumb = true

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: Self.icon(kind))
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: id) {
            guard kind == "image" else { return }
            image = await loader.image(id, thumb: hasThumb)
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "image": "photo"
        case "video": "film"
        case "audio": "waveform"
        default: "doc"
        }
    }
}

extension Int64 {
    /// 1.2 MB, as the web's `bytes()`.
    var byteText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Puts text (and optionally HTML) on the clipboard.
@MainActor
enum Clipboard {
    static func copy(_ text: String, html: String? = nil) {
        #if os(iOS)
        var item: [String: Any] = [UTType.utf8PlainText.identifier: text]
        if let html { item[UTType.html.identifier] = html }
        UIPasteboard.general.items = [item]
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        if let html { pb.setString(html, forType: .html) }
        pb.setString(text, forType: .string)
        #endif
    }
}
