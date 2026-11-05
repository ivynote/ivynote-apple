import IvynoteKit
import SwiftUI
import WebKit

/// The one note editor web view of a signed-in library. The page loads once;
/// opening another note swaps the document (guide 9: plain Markdown only).
@MainActor
@Observable
final class EditorHost: NSObject {
    let webView: WKWebView
    /// The editor has the keyboard (iPhone shows the formatting bar).
    private(set) var focused = false

    @ObservationIgnored private weak var engine: SyncEngine?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var queued: [(String, [String: Any])] = []
    @ObservationIgnored private(set) var noteID: String?
    /// The body the page has, to skip echoing its own edits back to it.
    @ObservationIgnored private var pageBody = ""
    @ObservationIgnored var onOpenNote: ((_ id: String, _ title: String) -> Void)?

    init(account: StoredAccount, engine: SyncEngine) {
        self.engine = engine
        let config = WKWebViewConfiguration()
        let schemes = EditorSchemeHandler(account: account)
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
        let titles: [[String: Any]] = engine.liveNotes
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { ["id": $0.id, "title": $0.title, "folder": engine.folders[$0.folderId]?.name ?? ""] }
        var kinds: [String: String] = [:]
        for a in engine.attachments.values { kinds[a.id] = a.kind }
        call("ivy.setTitles(list)", ["list": titles])
        call("ivy.setKinds(map)", ["map": kinds])
        #if os(iOS)
        let size = 17
        #else
        let size = 15
        #endif
        call("ivy.load(p)", ["p": ["id": note.id, "body": note.body, "readonly": note.isTrashed, "fontSize": size, "focus": focus] as [String: Any]])
    }

    /// The note's body changed outside the editor (pull, merge).
    func bodyChanged(_ id: String, _ body: String) {
        guard id == noteID, body != pageBody else { return }
        pageBody = body
        call("ivy.setBody(id, body)", ["id": id, "body": body])
    }

    func setReadonly(_ ro: Bool) { call("ivy.setReadonly(ro)", ["ro": ro]) }
    func setTheme(dark: Bool) { call("ivy.setTheme(dark)", ["dark": dark]) }
    func focus() { call("ivy.focus(true)", [:]) }
    func command(_ name: String) { call("ivy.command(name)", ["name": name]) }

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
            guard let id = m["id"] as? String, id == noteID, let text = m["body"] as? String else { return }
            pageBody = text
            engine?.updateNote(id, .init(body: text))
        case "open":
            onOpenNote?(m["id"] as? String ?? "", m["title"] as? String ?? "")
        case "focus":
            focused = m["focused"] as? Bool ?? false
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
        if let id = noteID, let note = engine?.notes[id] { open(note, focus: false) }
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
