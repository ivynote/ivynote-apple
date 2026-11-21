import Foundation
import Testing
@testable import IvynoteKit

private final class DirectTestTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    var sent: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        return try handler(request)
    }
}

private func hexData(_ hex: String) -> Data {
    let chars = Array(hex.filter { !$0.isWhitespace })
    var out = Data(capacity: chars.count / 2)
    var i = 0
    while i + 1 < chars.count {
        out.append(UInt8(String(chars[i...i + 1]), radix: 16)!)
        i += 2
    }
    return out
}

@Suite struct BlobCryptoTests {
    /// RFC draft-irtf-cfrg-xchacha Section A.3.1 official test vector.
    @Test func rfcXChaCha20Poly1305TestVector() throws {
        let key = hexData("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        let nonce = hexData("404142434445464748494a4b4c4d4e4f5051525354555657")
        let aad = hexData("50515253c0c1c2c3c4c5c6c7")
        let plaintext = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let expectedCT = hexData(
            "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb" +
            "731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452" +
            "2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9" +
            "21f9664c97637da9768812f615c68b13b52e"
        )
        let expectedTag = hexData("c0875924c1c7987947deafd8780acf49")

        let sealed = try BlobCrypto.xchachaSeal(key: key, nonce24: nonce, plaintext: plaintext, aad: aad)
        #expect(sealed == expectedCT + expectedTag)

        let opened = try BlobCrypto.xchachaOpen(key: key, nonce24: nonce, ciphertextWithTag: sealed, aad: aad)
        #expect(opened == plaintext)
    }

    @Test func encryptsAndDecryptsEmptyAndMultiChunkBlobs() throws {
        let key = Data((0..<32).map { UInt8($0) })

        // Empty file still produces one final chunk (40 bytes).
        let emptyCipher = try BlobCrypto.encryptBlob(key: key, blobID: "att00001", plaintext: Data())
        #expect(emptyCipher.count == BlobCrypto.overhead)
        #expect(BlobCrypto.sealedSize(plainSize: 0) == Int64(emptyCipher.count))
        #expect(BlobCrypto.plainSize(sealedSize: Int64(emptyCipher.count)) == 0)
        #expect(try BlobCrypto.decryptBlob(key: key, blobID: "att00001", ciphertext: emptyCipher).isEmpty)

        // Multi-chunk with custom small chunkSize (64 bytes) across 3.5 chunks.
        let plain = Data((0..<220).map { UInt8(($0 * 13 + 7) & 0xff) })
        let cipher = try BlobCrypto.encryptBlob(key: key, blobID: "att00002", plaintext: plain, chunkSize: 64)
        #expect(Int64(cipher.count) == BlobCrypto.sealedSize(plainSize: Int64(plain.count), chunkSize: 64))
        #expect(BlobCrypto.plainSize(sealedSize: Int64(cipher.count), chunkSize: 64) == Int64(plain.count))
        #expect(try BlobCrypto.decryptBlob(key: key, blobID: "att00002", ciphertext: cipher, chunkSize: 64) == plain)

        // Wrong blobID or tampered byte fails authentication.
        #expect(throws: BlobCryptoError.corruptedChunk(0)) {
            _ = try BlobCrypto.decryptBlob(key: key, blobID: "wrong-id", ciphertext: cipher, chunkSize: 64)
        }
        var tampered = cipher
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: BlobCryptoError.corruptedChunk(3)) {
            _ = try BlobCrypto.decryptBlob(key: key, blobID: "att00002", ciphertext: tampered, chunkSize: 64)
        }
    }

    @Test func decryptsCrossChunkByteRanges() throws {
        let key = Data((0..<32).map { UInt8(255 - $0) })
        let plain = Data((0..<250).map { UInt8($0 & 0xff) })
        let cipher = try BlobCrypto.encryptBlob(key: key, blobID: "vid00001", plaintext: plain, chunkSize: 64)

        // Span across chunks 1..2 (bytes 70...180).
        let plan = try BlobCrypto.cipherRange(
            plainStart: 70,
            plainEnd: 180,
            totalPlain: Int64(plain.count),
            totalSealed: Int64(cipher.count),
            chunkSize: 64
        )
        #expect(plan.firstChunk == 1 && plan.lastChunk == 2 && plan.totalChunks == 4)
        let slice = cipher[Int(plan.cipherStart)...Int(plan.cipherEnd)]
        let decrypted = try BlobCrypto.decryptChunkRange(key: key, blobID: "vid00001", cipherSlice: Data(slice), plan: plan, chunkSize: 64)
        #expect(decrypted == Data(plain[70...180]))
    }
}

@Suite struct DirectTransferTests {
    let server = try! ServerAddress(parsing: "https://notes.example.com")
    static let attJSON = #"{"id":"att00000042","name":"doc.bin","mime":"application/octet-stream","kind":"file","size":11,"sha256":"abc","storage":"s3","hasThumb":false,"refs":0,"public":false,"seq":9,"createdAt":1,"updatedAt":2}"#

    @Test func directUploadEncryptsAndPutsToS3WithoutBearerToken() async throws {
        let key = Data((0..<32).map { UInt8($0 + 1) })
        let keyB64 = key.base64EncodedString()
        let payload = Data("hello world".utf8)
        let captured = NSLock()
        nonisolated(unsafe) var putBody: Data?

        let transport = DirectTestTransport { req in
            let url = req.url!
            let method = req.httpMethod ?? "GET"
            if method == "POST" && url.path() == "/api/v1/attachments/upload-intent" {
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
                let body = """
                {"direct":true,"intentToken":"tok-sealed","id":"att00000042","key":"\(keyB64)","blobId":"att00000042","chunkSize":1048576,"uploadUrl":"https://s3.example.net/bucket/obj?X-Amz-Signature=abc","expiresAt":9999999999999}
                """
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            if method == "PUT" && url.host() == "s3.example.net" {
                // Must NEVER leak Ivynote Bearer token to S3.
                #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
                captured.withLock { putBody = req.httpBody }
                return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if method == "POST" && url.path() == "/api/v1/attachments/upload-complete" {
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
                let body = #"{"attachment":\#(Self.attJSON),"duplicate":false}"#
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }

        let api = APIClient(server: server, token: "tok", transport: transport)
        let res = try await api.upload(payload, name: "doc.bin", mime: "application/octet-stream")
        #expect(res.attachment.id == "att00000042" && !res.duplicate)
        #expect(transport.sent.map { "\($0.httpMethod ?? "") \($0.url!.host()!)\($0.url!.path())" } == [
            "POST notes.example.com/api/v1/attachments/upload-intent",
            "PUT s3.example.net/bucket/obj",
            "POST notes.example.com/api/v1/attachments/upload-complete",
        ])

        let cipher = try #require(captured.withLock { putBody })
        let decrypted = try BlobCrypto.decryptBlob(key: key, blobID: "att00000042", ciphertext: cipher)
        #expect(decrypted == payload)
    }

    @Test func directUploadShortCircuitsOnDuplicate() async throws {
        let transport = DirectTestTransport { req in
            let url = req.url!
            if req.httpMethod == "POST" && url.path() == "/api/v1/attachments/upload-intent" {
                let body = #"{"direct":false,"duplicate":true,"attachment":\#(Self.attJSON)}"#
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let api = APIClient(server: server, token: "tok", transport: transport)
        let res = try await api.upload(Data("hello world".utf8), name: "doc.bin", mime: "application/octet-stream")
        #expect(res.duplicate && res.attachment.id == "att00000042")
        #expect(transport.sent.count == 1)
    }

    @Test func directUploadFallsBackToMultipartWhenS3PutFails() async throws {
        let key = Data(repeating: 0x22, count: 32).base64EncodedString()
        let transport = DirectTestTransport { req in
            let url = req.url!
            if req.httpMethod == "POST" && url.path() == "/api/v1/attachments/upload-intent" {
                let body = """
                {"direct":true,"intentToken":"tok-sealed","id":"att00000042","key":"\(key)","blobId":"att00000042","chunkSize":1048576,"uploadUrl":"https://s3.example.net/bucket/obj","expiresAt":9999999999999}
                """
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            if req.httpMethod == "PUT" && url.host() == "s3.example.net" {
                return (Data(), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            if req.httpMethod == "POST" && url.path() == "/api/v1/attachments" {
                let body = #"{"attachment":\#(Self.attJSON),"duplicate":false}"#
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }

        let api = APIClient(server: server, token: "tok", transport: transport)
        let res = try await api.upload(Data("hello world".utf8), name: "doc.bin", mime: "application/octet-stream")
        #expect(res.attachment.id == "att00000042")
        #expect(transport.sent.map(\.url!.path) == [
            "/api/v1/attachments/upload-intent",
            "/bucket/obj",
            "/api/v1/attachments",
        ])
    }

    @Test func directDownloadUsesCdnWithPresignFallbackAndChunkedRanges() async throws {
        let key = Data((0..<32).map { UInt8($0 ^ 0x5a) })
        let keyB64 = key.base64EncodedString()
        let plain = Data((0..<200).map { UInt8(($0 * 7) & 0xff) })
        let cipher = try BlobCrypto.encryptBlob(key: key, blobID: "att00000099", plaintext: plain, chunkSize: 64)

        let transport = DirectTestTransport { req in
            let url = req.url!
            if url.path() == "/api/v1/attachments/att00000099/grant" {
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
                let body = """
                {"direct":true,"url":"https://cdn.example.net/obj","fallbackUrl":"https://s3.example.net/obj?sig=1","key":"\(keyB64)","blobId":"att00000099","mime":"video/mp4","size":\(plain.count),"sealedSize":\(cipher.count),"chunkSize":64,"expiresAt":9999999999999}
                """
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            if url.host() == "cdn.example.net" {
                #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
                // Simulate CDN error -> client must fall back to presigned S3 URL.
                return (Data(), HTTPURLResponse(url: url, statusCode: 502, httpVersion: nil, headerFields: nil)!)
            }
            if url.host() == "s3.example.net" {
                #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
                if let range = req.value(forHTTPHeaderField: "Range"),
                   let spec = ByteRangeSpec.parse(range, totalLength: Int64(cipher.count)) {
                    let sub = Data(cipher[Int(spec.start)...Int(spec.end)])
                    return (sub, HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes \(spec.start)-\(spec.end)/\(cipher.count)"])!)
                }
                return (cipher, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }

        let api = APIClient(server: server, token: "tok", transport: transport)
        let cache = AttachmentGrantCache()

        // Full download: grant -> CDN (502) -> S3 presign (200) -> decrypt.
        let full = try await api.downloadAttachment("att00000099", grantCache: cache)
        #expect(full.data == plain && full.mime == "video/mp4")

        // Range download: reuses cached grant (no second /grant call) -> Range decrypt.
        let ranged = try await api.downloadAttachmentRange("att00000099", rangeHeader: "bytes=50-140", grantCache: cache)
        #expect(ranged.status == 206)
        #expect(ranged.headers["Content-Range"] == "bytes 50-140/200")
        #expect(ranged.data == Data(plain[50...140]))
        let grantCalls = transport.sent.filter { $0.url?.path() == "/api/v1/attachments/att00000099/grant" }
        #expect(grantCalls.count == 1)
    }

    @Test func directDownloadFallsBackToRawWhenNotDirect() async throws {
        let plain = Data("local-file-bytes".utf8)
        let transport = DirectTestTransport { req in
            let url = req.url!
            if url.path() == "/api/v1/attachments/att00000055/grant" {
                let body = #"{"direct":false,"mime":"text/plain","size":16}"#
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            if url.path() == "/api/v1/attachments/att00000055/raw" {
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
                return (plain, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!)
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let api = APIClient(server: server, token: "tok", transport: transport)
        let res = try await api.downloadAttachment("att00000055")
        #expect(res.data == plain && res.mime == "text/plain")
    }
}
