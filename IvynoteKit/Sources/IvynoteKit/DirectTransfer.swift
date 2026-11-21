import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `GET /api/v1/attachments/{id}/grant`
public struct AttachmentGrant: Decodable, Equatable, Sendable {
    public var direct: Bool
    public var url: String
    public var fallbackUrl: String
    public var key: String
    public var blobId: String
    public var mime: String
    public var size: Int64
    public var sealedSize: Int64
    public var chunkSize: Int
    public var expiresAt: Millis

    public init(
        direct: Bool = false,
        url: String = "",
        fallbackUrl: String = "",
        key: String = "",
        blobId: String = "",
        mime: String = "application/octet-stream",
        size: Int64 = 0,
        sealedSize: Int64 = 0,
        chunkSize: Int = BlobCrypto.chunkSize,
        expiresAt: Millis = 0
    ) {
        self.direct = direct
        self.url = url
        self.fallbackUrl = fallbackUrl
        self.key = key
        self.blobId = blobId
        self.mime = mime
        self.size = size
        self.sealedSize = sealedSize
        self.chunkSize = chunkSize
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direct = try c.value(.direct, false)
        url = try c.value(.url, "")
        fallbackUrl = try c.value(.fallbackUrl, "")
        key = try c.value(.key, "")
        blobId = try c.value(.blobId, "")
        mime = try c.value(.mime, "application/octet-stream")
        size = try c.value(.size, 0)
        sealedSize = try c.value(.sealedSize, 0)
        chunkSize = try c.value(.chunkSize, BlobCrypto.chunkSize)
        expiresAt = try c.value(.expiresAt, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case direct, url, fallbackUrl, key, blobId, mime, size, sealedSize, chunkSize, expiresAt
    }
}

/// `POST /api/v1/attachments/upload-intent` request body.
public struct UploadIntentInput: Encodable, Sendable {
    public var name: String
    public var mime: String
    public var size: Int64
    public var sha256: String
    public var width: Int?
    public var height: Int?
    public var thumbSize: Int64?

    public init(
        name: String,
        mime: String,
        size: Int64,
        sha256: String,
        width: Int? = nil,
        height: Int? = nil,
        thumbSize: Int64? = nil
    ) {
        self.name = name
        self.mime = mime
        self.size = size
        self.sha256 = sha256
        self.width = width
        self.height = height
        self.thumbSize = thumbSize
    }
}

/// `POST /api/v1/attachments/upload-intent` response.
public struct UploadIntentResult: Decodable, Sendable {
    public var direct: Bool
    public var duplicate: Bool
    public var attachment: Attachment?
    public var intentToken: String
    public var id: String
    public var key: String
    public var blobId: String
    public var chunkSize: Int
    public var uploadUrl: String
    public var thumbUploadUrl: String
    public var thumbBlobId: String
    public var expiresAt: Millis

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direct = try c.value(.direct, false)
        duplicate = try c.value(.duplicate, false)
        attachment = try c.decodeIfPresent(Attachment.self, forKey: .attachment)
        intentToken = try c.value(.intentToken, "")
        id = try c.value(.id, "")
        key = try c.value(.key, "")
        blobId = try c.value(.blobId, "")
        chunkSize = try c.value(.chunkSize, BlobCrypto.chunkSize)
        uploadUrl = try c.value(.uploadUrl, "")
        thumbUploadUrl = try c.value(.thumbUploadUrl, "")
        thumbBlobId = try c.value(.thumbBlobId, "")
        expiresAt = try c.value(.expiresAt, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case direct, duplicate, attachment, intentToken, id, key, blobId, chunkSize, uploadUrl, thumbUploadUrl, thumbBlobId, expiresAt
    }
}

/// Short-lived in-memory cache of `/attachments/{id}/grant` responses so video
/// seeking (`Range` requests) and repeated reads avoid hitting the app server
/// on every chunk.
public final class AttachmentGrantCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: AttachmentGrant] = [:]
    private let marginMs: Millis
    private let now: @Sendable () -> Millis

    public init(marginMs: Millis = 60_000, now: @escaping @Sendable () -> Millis = { Millis(Date().timeIntervalSince1970 * 1000) }) {
        self.marginMs = marginMs
        self.now = now
    }

    public func get(id: String, thumb: Bool) -> AttachmentGrant? {
        let key = "\(id)|\(thumb ? "1" : "0")"
        let current = now()
        return lock.withLock {
            guard let g = entries[key] else { return nil }
            if g.expiresAt > 0 && g.expiresAt - marginMs <= current {
                entries[key] = nil
                return nil
            }
            return g
        }
    }

    public func put(id: String, thumb: Bool, grant: AttachmentGrant) {
        let key = "\(id)|\(thumb ? "1" : "0")"
        lock.withLock {
            if entries.count > 256 { entries.removeAll() }
            entries[key] = grant
        }
    }

    public func invalidate(id: String, thumb: Bool) {
        let key = "\(id)|\(thumb ? "1" : "0")"
        lock.withLock { entries[key] = nil }
    }

    public func clear() {
        lock.withLock { entries.removeAll() }
    }
}

/// Parsed HTTP `Range: bytes=start-end` header.
public struct ByteRangeSpec: Equatable, Sendable {
    public let start: Int64
    public let end: Int64

    public static func parse(_ header: String, totalLength: Int64) -> ByteRangeSpec? {
        guard totalLength > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst("bytes=".count))
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let endStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
        let start: Int64
        var end: Int64
        if startStr.isEmpty {
            guard let suffix = Int64(endStr), suffix > 0 else { return nil }
            start = max(0, totalLength - suffix)
            end = totalLength - 1
        } else {
            guard let s = Int64(startStr), s >= 0 else { return nil }
            start = s
            if endStr.isEmpty {
                end = totalLength - 1
            } else {
                guard let e = Int64(endStr), e >= start else { return nil }
                end = min(e, totalLength - 1)
            }
        }
        guard start < totalLength, start <= end else { return nil }
        end = min(end, totalLength - 1)
        return ByteRangeSpec(start: start, end: end)
    }
}

/// Result of downloading an attachment range.
public struct DownloadedRange: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data
}

extension APIClient {
    private static let directThumbMaxSide = 480
    private static let directThumbMaxInput = 40 << 20

    // MARK: Direct Transfer API

    public func attachmentGrant(_ id: String, thumb: Bool = false, compat: Bool = false) async throws -> AttachmentGrant {
        var items: [URLQueryItem] = []
        if thumb { items.append(URLQueryItem(name: "thumb", value: "1")) }
        if compat { items.append(URLQueryItem(name: "compat", value: "1")) }
        return try await send("GET", "attachments/\(Self.segment(id))/grant" + Self.query(items))
    }

    public func createUploadIntent(_ input: UploadIntentInput) async throws -> UploadIntentResult {
        try await send("POST", "attachments/upload-intent", body: input)
    }

    public func completeUploadIntent(token: String, hasThumb: Bool) async throws -> UploadResult {
        struct Body: Encodable {
            var intentToken: String
            var hasThumb: Bool
        }
        return try await send("POST", "attachments/upload-complete", body: Body(intentToken: token, hasThumb: hasThumb))
    }

    /// Tries to upload directly to S3 with client-side XChaCha20-Poly1305
    /// encryption (`upload-intent` -> direct `PUT` to S3 -> `upload-complete`).
    /// Returns `nil` when direct S3 upload is unavailable or fails at S3 so the
    /// caller can seamlessly fall back to multipart `POST /attachments`.
    func tryDirectUpload(_ data: Data, name: String, mime: String) async throws -> UploadResult? {
        let sha256 = BlobCrypto.sha256Hex(data)
        let imageInfo: (width: Int, height: Int, thumb: Data?)? =
            mime.lowercased().hasPrefix("image/") && data.count <= Self.directThumbMaxInput
            ? Self.generateImageThumbnail(data)
            : nil

        let intent: UploadIntentResult
        do {
            intent = try await createUploadIntent(UploadIntentInput(
                name: name,
                mime: mime,
                size: Int64(data.count),
                sha256: sha256,
                width: imageInfo?.width,
                height: imageInfo?.height,
                thumbSize: imageInfo?.thumb.map { Int64($0.count) }
            ))
        } catch let e as APIError {
            // Propagate auth/quota/size/offline errors immediately; fall back on
            // older servers (404/405/501) or unexpected 4xx intent errors.
            if e.endsSession || e.status == 402 || e.status == 413 || e.isTransient {
                throw e
            }
            return nil
        }

        if intent.duplicate, let existing = intent.attachment {
            return UploadResult(attachment: existing, duplicate: true)
        }
        guard intent.direct,
              !intent.intentToken.isEmpty,
              !intent.uploadUrl.isEmpty,
              !intent.blobId.isEmpty,
              let keyData = Data(base64Encoded: intent.key), keyData.count == 32,
              let uploadURL = URL(string: intent.uploadUrl) else {
            return nil
        }

        let chunkSize = intent.chunkSize > 0 ? intent.chunkSize : BlobCrypto.chunkSize
        let sealedMain: Data
        do {
            sealedMain = try BlobCrypto.encryptBlob(key: keyData, blobID: intent.blobId, plaintext: data, chunkSize: chunkSize)
        } catch {
            return nil
        }

        // Direct S3 PUT: never attach Ivynote Authorization or cookies.
        do {
            try await putEncryptedBlob(to: uploadURL, data: sealedMain)
        } catch {
            return nil
        }

        var hasThumb = false
        if let thumbData = imageInfo?.thumb,
           !intent.thumbUploadUrl.isEmpty,
           !intent.thumbBlobId.isEmpty,
           let thumbURL = URL(string: intent.thumbUploadUrl) {
            if let sealedThumb = try? BlobCrypto.encryptBlob(key: keyData, blobID: intent.thumbBlobId, plaintext: thumbData, chunkSize: chunkSize),
               (try? await putEncryptedBlob(to: thumbURL, data: sealedThumb)) != nil {
                hasThumb = true
            }
        }

        do {
            return try await completeUploadIntent(token: intent.intentToken, hasThumb: hasThumb)
        } catch let e as APIError {
            if e.endsSession || e.status == 402 || e.status == 413 || e.isTransient {
                throw e
            }
            return nil
        }
    }

    /// Downloads an attachment, preferring direct S3/CDN encrypted transfer +
    /// local XChaCha20-Poly1305 decryption, and falling back to `/raw`.
    public func downloadAttachment(
        _ id: String,
        thumb: Bool = false,
        compat: Bool = false,
        grantCache: AttachmentGrantCache? = nil,
        mediaTransport: HTTPTransport? = nil
    ) async throws -> (data: Data, mime: String) {
        let fetchTransport = mediaTransport ?? transport

        if let grant = try await resolveGrant(id: id, thumb: thumb, compat: compat, grantCache: grantCache),
           grant.direct,
           let keyData = Data(base64Encoded: grant.key), keyData.count == 32,
           !grant.blobId.isEmpty {
            let chunkSize = grant.chunkSize > 0 ? grant.chunkSize : BlobCrypto.chunkSize
            for candidate in [grant.url, grant.fallbackUrl] where !candidate.isEmpty {
                guard let url = URL(string: candidate) else { continue }
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 300
                if let (cipher, http) = try? await fetchTransport.send(req),
                   (200..<300).contains(http.statusCode),
                   let plain = try? BlobCrypto.decryptBlob(key: keyData, blobID: grant.blobId, ciphertext: cipher, chunkSize: chunkSize) {
                    let mime = grant.mime.isEmpty ? "application/octet-stream" : grant.mime
                    return (plain, mime)
                }
            }
            grantCache?.invalidate(id: id, thumb: thumb)
        }

        // Fallback to authenticated `/api/v1/attachments/{id}/raw`.
        let req = rawRequest(id, thumb: thumb)
        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await fetchTransport.send(req)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, message: "")
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, mime)
    }

    /// Downloads a byte range of an attachment (used by video/audio seeking in
    /// `WKURLSchemeHandler`), decrypting only the needed 1 MiB chunks directly
    /// from S3/CDN when available, or falling back to `/raw`.
    public func downloadAttachmentRange(
        _ id: String,
        thumb: Bool = false,
        compat: Bool = false,
        rangeHeader: String,
        grantCache: AttachmentGrantCache? = nil,
        mediaTransport: HTTPTransport? = nil
    ) async throws -> DownloadedRange {
        let fetchTransport = mediaTransport ?? transport

        if let grant = try await resolveGrant(id: id, thumb: thumb, compat: compat, grantCache: grantCache),
           grant.direct,
           grant.size > 0,
           grant.sealedSize >= Int64(BlobCrypto.overhead),
           let keyData = Data(base64Encoded: grant.key), keyData.count == 32,
           !grant.blobId.isEmpty {
            guard let spec = ByteRangeSpec.parse(rangeHeader, totalLength: grant.size) else {
                return DownloadedRange(status: 416, headers: ["Content-Range": "bytes */\(grant.size)"], data: Data())
            }
            let chunkSize = grant.chunkSize > 0 ? grant.chunkSize : BlobCrypto.chunkSize
            if let plan = try? BlobCrypto.cipherRange(
                plainStart: spec.start,
                plainEnd: spec.end,
                totalPlain: grant.size,
                totalSealed: grant.sealedSize,
                chunkSize: chunkSize
            ) {
                for candidate in [grant.url, grant.fallbackUrl] where !candidate.isEmpty {
                    guard let url = URL(string: candidate) else { continue }
                    var req = URLRequest(url: url)
                    req.httpMethod = "GET"
                    req.setValue("bytes=\(plan.cipherStart)-\(plan.cipherEnd)", forHTTPHeaderField: "Range")
                    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                    req.timeoutInterval = 300
                    guard let (body, http) = try? await fetchTransport.send(req) else { continue }
                    let plain: Data?
                    if http.statusCode == 206 {
                        plain = try? BlobCrypto.decryptChunkRange(
                            key: keyData,
                            blobID: grant.blobId,
                            cipherSlice: body,
                            plan: plan,
                            chunkSize: chunkSize
                        )
                    } else if http.statusCode == 200,
                              let full = try? BlobCrypto.decryptBlob(key: keyData, blobID: grant.blobId, ciphertext: body, chunkSize: chunkSize),
                              Int(spec.end) < full.count {
                        plain = Data(full[Int(spec.start)...Int(spec.end)])
                    } else {
                        plain = nil
                    }
                    if let plain {
                        let mime = grant.mime.isEmpty ? "application/octet-stream" : grant.mime
                        return DownloadedRange(
                            status: 206,
                            headers: [
                                "Content-Type": mime,
                                "Accept-Ranges": "bytes",
                                "Content-Range": "bytes \(spec.start)-\(spec.end)/\(grant.size)",
                                "Content-Length": "\(plain.count)",
                            ],
                            data: plain
                        )
                    }
                }
                grantCache?.invalidate(id: id, thumb: thumb)
            }
        }

        // Fallback to `/raw` with the original Range header.
        var req = rawRequest(id, thumb: thumb)
        req.setValue(rangeHeader, forHTTPHeaderField: "Range")
        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await fetchTransport.send(req)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }
        var headers: [String: String] = [:]
        for name in ["Content-Type", "Content-Range", "Accept-Ranges", "Content-Length"] {
            if let v = http.value(forHTTPHeaderField: name) { headers[name] = v }
        }
        return DownloadedRange(status: http.statusCode, headers: headers, data: data)
    }

    // MARK: Internals

    private func resolveGrant(
        id: String,
        thumb: Bool,
        compat: Bool,
        grantCache: AttachmentGrantCache?
    ) async throws -> AttachmentGrant? {
        if let cached = grantCache?.get(id: id, thumb: thumb) {
            return cached
        }
        do {
            let grant = try await attachmentGrant(id, thumb: thumb, compat: compat)
            if grant.direct {
                grantCache?.put(id: id, thumb: thumb, grant: grant)
            }
            return grant
        } catch let e as APIError where e.endsSession {
            throw e
        } catch {
            return nil
        }
    }

    private func putEncryptedBlob(to url: URL, data: Data) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 600
        let (_, response) = try await transport.sendUpload(req)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server(status: response.statusCode, message: "direct upload failed")
        }
    }

    /// Computes image dimensions and an optional <=480px JPEG thumbnail using
    /// Apple's built-in ImageIO framework (supports JPEG, PNG, WebP, HEIC, GIF).
    static func generateImageThumbnail(_ data: Data) -> (width: Int, height: Int, thumb: Data?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = props[kCGImagePropertyPixelWidth] as? Int,
              var height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        if let orientation = props[kCGImagePropertyOrientation] as? UInt32,
           orientation >= 5 && orientation <= 8 {
            swap(&width, &height)
        }
        let maxSide = max(width, height)
        let targetSide = min(maxSide, directThumbMaxSide)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetSide,
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return (width, height, nil)
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return (width, height, nil)
        }
        let destOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(dest, cgThumb, destOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0 else {
            return (width, height, nil)
        }
        return (width, height, out as Data)
    }
}
