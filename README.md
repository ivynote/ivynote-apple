# 常青笔记 Ivynote for Apple platforms

Native client for iPhone, iPad and Mac. One SwiftUI app target, bundle ID
`app.ivynote` (one App Store record, universal purchase).

The server, web client, and the protocol this client implements live in the
[ivynote](../ivynote) repository. **The source of truth for the API and sync
protocol is `ivynote/client/docs/client-development-guide.md`**; this
repository does not keep a copy. Server changes that affect clients get an
issue here.

| | |
|---|---|
| Server API | `/api/v1`, tested against ivynote `dev` (2026-11) |
| Platforms | iOS / iPadOS 17+, macOS 14+ |
| Language | Swift 6, strict concurrency |

## Layout

```text
project.yml        XcodeGen spec; Ivynote.xcodeproj is generated, not committed
Config.xcconfig    shared settings; includes your git-ignored Local.xcconfig
App/               SwiftUI app (iOS + macOS)
IvynoteKit/        Swift package with no UI: API client, session, Keychain
                   (next: local SQLite store and the sync engine)
```

IvynoteKit holds everything that can be tested without a simulator. UI code
stays thin.

## Getting started

```bash
brew install xcodegen
cp Local.xcconfig.example Local.xcconfig   # set DEVELOPMENT_TEAM to your Team ID
make open
```

`make test` runs the IvynoteKit tests. `make test-live SERVER=http://127.0.0.1:18080`
also runs an account lifecycle test against a real server: it registers a
throwaway account, so use a disposable data directory, e.g. in `ivynote/server`:

```bash
IVY_MASTER_KEYS='k1:cUA297OzjWn7QmBrON/J1bDRS2v9NQJQUMTHFsS8Mwk=' go run . serve -data-dir /tmp/ivy-apple -http 127.0.0.1:18080
```

## Rules carried over from the guide

- Self-hosted: the user enters the server address; nothing is hard-coded.
  Plain `http` is accepted only on the local network (ATS
  `NSAllowsLocalNetworking`) and shows a warning unless it is this device.
- Bearer token only, no cookies; the token and cached user live in the
  Keychain (`AfterFirstUnlockThisDeviceOnly`).
- Session restore: open with the cached account, refresh with `GET /me`;
  only 401/403 end the session, network errors and 5xx mean offline.
- Never log tokens, passwords or note content.
- The admin console is not rebuilt here; admins get a link to `{server}/admin`.

## Roadmap

1. ~~Connect, sign in, sign up, session restore~~
2. Local store (SQLite) and sync engine: HLC, outbox, push/pull, SSE (guide ch. 6)
3. Library tree, note list, editor (CodeMirror 6 from `ivynote/client/packages/editor` in a WKWebView)
4. Attachments, offline upload queue
5. Search, `[[wiki links]]`, backlinks
6. Online features: history, sharing, media library, settings
