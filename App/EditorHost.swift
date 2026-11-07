import IvynoteKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The one note editor web view of a signed-in library. The page loads once;
/// opening another note swaps the document (guide 9: plain Markdown only).
@MainActor
@Observable
final class EditorHost: NSObject {
    let webView: WKWebView
    /// The editor has the keyboard (iPhone shows the formatting bar).
    private(set) var focused = false
    /// The 0-based body line at the top of the view, for the outline.
    private(set) var topLine = 0

    @ObservationIgnored private weak var engine: SyncEngine?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var queued: [(String, [String: Any])] = []
    @ObservationIgnored private(set) var noteID: String?
    /// The body the page has, to skip echoing its own edits back to it.
    @ObservationIgnored private var pageBody = ""
    @ObservationIgnored var onOpenNote: ((_ id: String, _ title: String) -> Void)?
    /// Files pasted or dropped into the editor.
    @ObservationIgnored var onFiles: ((_ files: [DroppedFile]) -> Void)?
    /// Shows documents without editing them (history versions): no changes,
    /// links or files come back from the page.
    let readonly: Bool

    struct DroppedFile {
        let name: String
        let mime: String
        let data: Data
    }

    init(account: StoredAccount?, engine: SyncEngine, readonly: Bool = false) {
        self.engine = engine
        self.readonly = readonly
        let config = WKWebViewConfiguration()
        let schemes = EditorSchemeHandler(account: account) { [weak engine] id in engine?.uploadFile(id) }
        config.setURLSchemeHandler(schemes, forURLScheme: EditorSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        let content = WKUserContentController()
        config.userContentController = content
        #if os(iOS)
        config.dataDetectorTypes = []
        #endif
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        content.add(WeakMessageHandler(self), name: "ivy")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.keyboardDismissMode = .interactive
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        #if DEBUG
        if #available(iOS 16.4, macOS 13.3, *) { webView.isInspectable = true }
        #endif
        webView.load(URLRequest(url: EditorSchemeHandler.pageURL))
    }

    // MARK: Swift → page

    func open(_ note: Note, focus: Bool) {
        guard let engine else { return }
        noteID = note.id
        pageBody = note.body
        topLine = 0
        let titles: [[String: Any]] = engine.liveNotes
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { ["id": $0.id, "title": $0.title, "folder": engine.folders[$0.folderId]?.name ?? ""] }
        call("ivy.setTitles(list)", ["list": titles])
        sendKinds()
        call("ivy.load(p)", ["p": ["id": note.id, "body": note.body, "readonly": readonly || note.isTrashed, "fontSize": Self.fontSize, "focus": focus] as [String: Any]])
    }

    /// Shows a body read-only, e.g. a version from the history.
    func show(_ body: String) {
        noteID = nil
        pageBody = body
        sendKinds()
        call("ivy.load(p)", ["p": ["id": "", "body": body, "readonly": true, "fontSize": Self.fontSize, "focus": false] as [String: Any]])
    }

    #if os(iOS)
    static let fontSize = 17
    #else
    static let fontSize = 15
    #endif

    private func sendKinds() {
        guard let engine else { return }
        var kinds: [String: String] = [:]
        for a in engine.attachments.values { kinds[a.id] = a.kind }
        for u in engine.uploads.values { kinds[u.id] = u.kind }
        call("ivy.setKinds(map)", ["map": kinds])
    }

    /// Writes a just-added file into the open note at the cursor, on a line
    /// of its own (guide 7.1).
    func insertFile(_ file: AddedFile) {
        call("ivy.setKind(id, kind)", ["id": file.id, "kind": file.kind])
        call("ivy.insert(text, true)", ["text": file.markdown])
    }

    /// The notes linking to the open one, listed below its body.
    func setBacklinks(_ list: [(id: String, title: String, context: String)]) {
        call("ivy.setBacklinks(list)", ["list": list.map { ["id": $0.id, "title": $0.title, "context": $0.context] }])
    }

    /// Markdown rendered as the editor renders it, for copying as rich text.
    func render(_ markdown: String) async -> String? {
        guard ready else { return nil }
        let result = try? await webView.callAsyncJavaScript("return ivy.render(md)", arguments: ["md": markdown], contentWorld: .page)
        return result as? String
    }

    /// The note's body changed outside the editor (pull, merge).
    func bodyChanged(_ id: String, _ body: String) {
        guard id == noteID, body != pageBody else { return }
        pageBody = body
        call("ivy.setBody(id, body)", ["id": id, "body": body])
    }

    func setReadonly(_ ro: Bool) { call("ivy.setReadonly(ro)", ["ro": ro]) }
    func setTheme(dark: Bool) { call("ivy.setTheme(dark)", ["dark": dark]) }
    /// The placeholder, formatting words and backlinks in the interface language.
    func setLanguage(_ language: Language) { call("ivy.setLanguage(lang)", ["lang": language.rawValue]) }
    func focus() { call("ivy.focus(true)", [:]) }
    func command(_ name: String) { call("ivy.command(name)", ["name": name]) }
    /// Scrolls to a 0-based line of the body, e.g. a heading from the outline.
    func scrollToLine(_ line: Int) { call("ivy.scrollToLine(line)", ["line": line]) }

    private func call(_ js: String, _ args: [String: Any]) {
        guard ready else {
            queued.append((js, args))
            return
        }
        webView.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { result in
            if case .failure(let error) = result { editorLog.error("call \(js.prefix(24), privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: Page → Swift

    fileprivate func receive(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            let q = queued
            queued = []
            for (js, args) in q { call(js, args) }
        case "change":
            guard !readonly, let id = m["id"] as? String, id == noteID, let text = m["body"] as? String else { return }
            pageBody = text
            engine?.updateNote(id, .init(body: text))
        case "open":
            guard !readonly else { return }
            onOpenNote?(m["id"] as? String ?? "", m["title"] as? String ?? "")
        case "files":
            guard !readonly, let list = m["files"] as? [[String: Any]] else { return }
            let files = list.compactMap { f -> DroppedFile? in
                guard let b64 = f["data"] as? String, let data = Data(base64Encoded: b64) else { return nil }
                let mime = f["type"] as? String ?? ""
                var name = f["name"] as? String ?? ""
                // A pasted image has no name (guide 7.1): image-<time>.<ext>.
                if name.isEmpty || name == "image.png" && mime.hasPrefix("image/") {
                    name = DroppedFile.pastedName(mime: mime)
                }
                return DroppedFile(name: name, mime: mime, data: data)
            }
            if !files.isEmpty { onFiles?(files) }
        case "focus":
            focused = m["focused"] as? Bool ?? false
        case "scroll":
            topLine = m["line"] as? Int ?? 0
        case "error", "log":
            editorLog.notice("page \(type, privacy: .public): \(String(describing: m["message"] ?? ""), privacy: .public)")
        default:
            break
        }
    }
}

extension EditorHost: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == EditorSchemeHandler.scheme { return .allow }
        openExternally(url)
        return .cancel
    }

    /// `window.open` (links in the note) goes to the system browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { openExternally(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page is gone (memory pressure); load it again and reopen the note.
        ready = false
        webView.load(URLRequest(url: EditorSchemeHandler.pageURL))
        if let id = noteID, let note = engine?.notes[id] { open(note, focus: false) } else if readonly { show(pageBody) }
    }

    private func openExternally(_ url: URL) {
        guard ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

extension EditorHost.DroppedFile {
    /// `image-<timestamp>.<ext>`, for pasted images and camera shots.
    static func pastedName(mime: String, now: Date = Date()) -> String {
        let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "png"
        return "image-\(Int64(now.timeIntervalSince1970 * 1000)).\(ext)"
    }
}

/// WKUserContentController keeps its handlers alive; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var host: EditorHost?
    init(_ host: EditorHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { host?.receive(message.body) }
    }
}

// MARK: SwiftUI

#if os(iOS)
struct MarkdownEditor: UIViewRepresentable {
    let host: EditorHost
    func makeUIView(context: Context) -> UIView { Container(host.webView) }
    func updateUIView(_ view: UIView, context: Context) {}

    final class Container: UIView {
        init(_ web: WKWebView) {
            super.init(frame: .zero)
            web.removeFromSuperview()
            web.translatesAutoresizingMaskIntoConstraints = false
            addSubview(web)
            NSLayoutConstraint.activate([
                web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
                web.topAnchor.constraint(equalTo: topAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        required init?(coder: NSCoder) { nil }
    }
}
#else
struct MarkdownEditor: NSViewRepresentable {
    let host: EditorHost
    func makeNSView(context: Context) -> NSView { Container(host.webView) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Container: NSView {
        init(_ web: WKWebView) {
            super.init(frame: .zero)
            web.removeFromSuperview()
            web.translatesAutoresizingMaskIntoConstraints = false
            addSubview(web)
            NSLayoutConstraint.activate([
                web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
                web.topAnchor.constraint(equalTo: topAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        required init?(coder: NSCoder) { nil }
    }
}
#endif
