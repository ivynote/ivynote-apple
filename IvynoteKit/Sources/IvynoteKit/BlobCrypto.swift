import CryptoKit
import Foundation
import Security

public enum BlobCryptoError: Error, Equatable, Sendable {
    case invalidKey
    case invalidNonce
    case invalidSize
    case randomFailed
    case corruptedChunk(Int)
    case rangeOutOfBounds
}

/// Chunked XChaCha20-Poly1305 blob encryption/decryption matching Ivynote's
/// server format (`server/internal/crypto/blob.go`):
///
/// Each chunk (up to `chunkSize` plaintext bytes, default 1 MiB) is stored as:
///   `nonce (24 bytes) || ciphertext (N bytes) || Poly1305 tag (16 bytes)`
/// with AAD:
///   `"ivy:blob:v1|<blobID>|<chunkIndex>|<final>"` (`final` is `"1"` on the
///   last chunk, `"0"` otherwise).
///
/// Built purely on Apple's `CryptoKit.ChaChaPoly` + RFC draft-irtf-cfrg-xchacha
/// `HChaCha20` subkey derivation, requiring zero external dependencies.
public enum BlobCrypto {
    public static let chunkSize = 1 << 20
    public static let nonceSize = 24
    public static let tagSize = 16
    public static let overhead = nonceSize + tagSize
    public static let sealedChunkSize = chunkSize + overhead

    public struct CipherRangePlan: Equatable, Sendable {
        public let cipherStart: Int64
        public let cipherEnd: Int64
        public let firstChunk: Int
        public let lastChunk: Int
        public let totalChunks: Int
        public let skipPrefix: Int
        public let takeLength: Int
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func blobAAD(blobID: String, index: Int, isFinal: Bool) -> Data {
        Data("ivy:blob:v1|\(blobID)|\(index)|\(isFinal ? "1" : "0")".utf8)
    }

    /// Computes the exact sealed ciphertext length for `plainSize` plaintext bytes.
    public static func sealedSize(plainSize: Int64, chunkSize: Int = chunkSize) -> Int64 {
        guard plainSize >= 0, chunkSize > 0 else { return 0 }
        if plainSize == 0 { return Int64(overhead) }
        let cs = Int64(chunkSize)
        let chunks = (plainSize + cs - 1) / cs
        return plainSize + chunks * Int64(overhead)
    }

    /// Computes the exact plaintext length for `sealedSize` ciphertext bytes, or nil if invalid.
    public static func plainSize(sealedSize: Int64, chunkSize: Int = chunkSize) -> Int64? {
        guard sealedSize >= Int64(overhead), chunkSize > 0 else { return nil }
        let sc = Int64(chunkSize + overhead)
        let full = sealedSize / sc
        let rem = sealedSize % sc
        if rem == 0 {
            return full * Int64(chunkSize)
        }
        guard rem >= Int64(overhead) else { return nil }
        return full * Int64(chunkSize) + (rem - Int64(overhead))
    }

    /// RFC draft-irtf-cfrg-xchacha Section 2.2 HChaCha20 subkey derivation.
    public static func hchacha20(key: Data, nonce16: Data) throws -> Data {
        guard key.count == 32 else { throw BlobCryptoError.invalidKey }
        guard nonce16.count == 16 else { throw BlobCryptoError.invalidNonce }

        var s: [UInt32] = [
            0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
            loadLE32(key, 0), loadLE32(key, 4), loadLE32(key, 8), loadLE32(key, 12),
            loadLE32(key, 16), loadLE32(key, 20), loadLE32(key, 24), loadLE32(key, 28),
            loadLE32(nonce16, 0), loadLE32(nonce16, 4), loadLE32(nonce16, 8), loadLE32(nonce16, 12),
        ]

        for _ in 0..<10 {
            quarterRound(&s, 0, 4, 8, 12)
            quarterRound(&s, 1, 5, 9, 13)
            quarterRound(&s, 2, 6, 10, 14)
            quarterRound(&s, 3, 7, 11, 15)

            quarterRound(&s, 0, 5, 10, 15)
            quarterRound(&s, 1, 6, 11, 12)
            quarterRound(&s, 2, 7, 8, 13)
            quarterRound(&s, 3, 4, 9, 14)
        }

        var out = Data(capacity: 32)
        for idx in [0, 1, 2, 3, 12, 13, 14, 15] {
            var le = s[idx].littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// Single-shot XChaCha20-Poly1305 AEAD seal (returns `ciphertext || tag`).
    public static func xchachaSeal(key: Data, nonce24: Data, plaintext: Data, aad: Data) throws -> Data {
        guard key.count == 32 else { throw BlobCryptoError.invalidKey }
        guard nonce24.count == nonceSize else { throw BlobCryptoError.invalidNonce }
        let subkey = SymmetricKey(data: try hchacha20(key: key, nonce16: Data(nonce24.prefix(16))))
        var n12 = Data(repeating: 0, count: 4)
        n12.append(contentsOf: nonce24.suffix(8))
        let nonce = try ChaChaPoly.Nonce(data: n12)
        let sealed = try ChaChaPoly.seal(plaintext, using: subkey, nonce: nonce, authenticating: aad)
        var out = Data(capacity: sealed.ciphertext.count + tagSize)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Single-shot XChaCha20-Poly1305 AEAD open (`ciphertextWithTag` is `ciphertext || tag`).
    public static func xchachaOpen(key: Data, nonce24: Data, ciphertextWithTag: Data, aad: Data) throws -> Data {
        guard key.count == 32 else { throw BlobCryptoError.invalidKey }
        guard nonce24.count == nonceSize else { throw BlobCryptoError.invalidNonce }
        guard ciphertextWithTag.count >= tagSize else { throw BlobCryptoError.invalidSize }
        let subkey = SymmetricKey(data: try hchacha20(key: key, nonce16: Data(nonce24.prefix(16))))
        var n12 = Data(repeating: 0, count: 4)
        n12.append(contentsOf: nonce24.suffix(8))
        let nonce = try ChaChaPoly.Nonce(data: n12)
        let ctCount = ciphertextWithTag.count - tagSize
        let ct = ciphertextWithTag.prefix(ctCount)
        let tag = ciphertextWithTag.suffix(tagSize)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: subkey, authenticating: aad)
    }

    /// Encrypts `plaintext` into Ivynote's chunked XChaCha20-Poly1305 blob format.
    public static func encryptBlob(key: Data, blobID: String, plaintext: Data, chunkSize: Int = chunkSize) throws -> Data {
        guard key.count == 32 else { throw BlobCryptoError.invalidKey }
        guard chunkSize > 0 else { throw BlobCryptoError.invalidSize }

        let expected = Int(sealedSize(plainSize: Int64(plaintext.count), chunkSize: chunkSize))
        var out = Data(capacity: expected)

        if plaintext.isEmpty {
            let nonce = try randomBytes(nonceSize)
            let sealed = try xchachaSeal(key: key, nonce24: nonce, plaintext: Data(), aad: blobAAD(blobID: blobID, index: 0, isFinal: true))
            out.append(nonce)
            out.append(sealed)
            return out
        }

        let base = plaintext.startIndex
        let total = plaintext.count
        var offset = 0
        var idx = 0
        while offset < total {
            let end = min(offset + chunkSize, total)
            let isFinal = end == total
            let chunk = plaintext[base + offset ..< base + end]
            let nonce = try randomBytes(nonceSize)
            let sealed = try xchachaSeal(key: key, nonce24: nonce, plaintext: Data(chunk), aad: blobAAD(blobID: blobID, index: idx, isFinal: isFinal))
            out.append(nonce)
            out.append(sealed)
            offset = end
            idx += 1
        }
        return out
    }

    /// Decrypts a complete Ivynote chunked XChaCha20-Poly1305 blob.
    public static func decryptBlob(key: Data, blobID: String, ciphertext: Data, chunkSize: Int = chunkSize) throws -> Data {
        guard key.count == 32 else { throw BlobCryptoError.invalidKey }
        guard chunkSize > 0 else { throw BlobCryptoError.invalidSize }
        guard let expectedPlain = plainSize(sealedSize: Int64(ciphertext.count), chunkSize: chunkSize) else {
            throw BlobCryptoError.invalidSize
        }

        let sc = chunkSize + overhead
        var out = Data(capacity: Int(expectedPlain))
        let base = ciphertext.startIndex
        let total = ciphertext.count
        var offset = 0
        var idx = 0
        while offset < total {
            let end = min(offset + sc, total)
            let isFinal = end == total
            let slice = ciphertext[base + offset ..< base + end]
            guard slice.count >= overhead else { throw BlobCryptoError.corruptedChunk(idx) }
            let nonce = Data(slice.prefix(nonceSize))
            let body = Data(slice.dropFirst(nonceSize))
            do {
                let plain = try xchachaOpen(key: key, nonce24: nonce, ciphertextWithTag: body, aad: blobAAD(blobID: blobID, index: idx, isFinal: isFinal))
                out.append(plain)
            } catch {
                throw BlobCryptoError.corruptedChunk(idx)
            }
            offset = end
            idx += 1
        }
        return out
    }

    /// Plans the exact inclusive ciphertext byte range needed to satisfy an
    /// inclusive plaintext byte range `[plainStart, plainEnd]`.
    public static func cipherRange(
        plainStart: Int64,
        plainEnd: Int64,
        totalPlain: Int64,
        totalSealed: Int64,
        chunkSize: Int = chunkSize
    ) throws -> CipherRangePlan {
        guard chunkSize > 0, totalPlain > 0, totalSealed >= Int64(overhead),
              plainStart >= 0, plainEnd >= plainStart, plainEnd < totalPlain else {
            throw BlobCryptoError.rangeOutOfBounds
        }
        let cs = Int64(chunkSize)
        let sc = Int64(chunkSize + overhead)
        let totalChunks = Int((totalPlain + cs - 1) / cs)
        let firstChunk = Int(plainStart / cs)
        let lastChunk = Int(plainEnd / cs)
        let cipherStart = Int64(firstChunk) * sc
        let cipherEnd = min(totalSealed - 1, Int64(lastChunk + 1) * sc - 1)
        let skipPrefix = Int(plainStart - Int64(firstChunk) * cs)
        let takeLength = Int(plainEnd - plainStart + 1)
        return CipherRangePlan(
            cipherStart: cipherStart,
            cipherEnd: cipherEnd,
            firstChunk: firstChunk,
            lastChunk: lastChunk,
            totalChunks: totalChunks,
            skipPrefix: skipPrefix,
            takeLength: takeLength
        )
    }

    /// Decrypts a contiguous slice of sealed chunks described by `plan` and
    /// returns the requested plaintext subrange.
    public static func decryptChunkRange(
        key: Data,
        blobID: String,
        cipherSlice: Data,
        plan: CipherRangePlan,
        chunkSize: Int = chunkSize
    ) throws -> Data {
        guard key.count == 32 else { throw BlobCryptoError.invalidKey }
        let sc = chunkSize + overhead
        let base = cipherSlice.startIndex
        let total = cipherSlice.count
        var offset = 0
        var plain = Data()
        for idx in plan.firstChunk...plan.lastChunk {
            let end = min(offset + sc, total)
            guard end - offset >= overhead else { throw BlobCryptoError.corruptedChunk(idx) }
            let slice = cipherSlice[base + offset ..< base + end]
            let isFinal = idx == plan.totalChunks - 1
            let nonce = Data(slice.prefix(nonceSize))
            let body = Data(slice.dropFirst(nonceSize))
            do {
                let decrypted = try xchachaOpen(key: key, nonce24: nonce, ciphertextWithTag: body, aad: blobAAD(blobID: blobID, index: idx, isFinal: isFinal))
                plain.append(decrypted)
            } catch {
                throw BlobCryptoError.corruptedChunk(idx)
            }
            offset = end
        }
        guard plan.skipPrefix >= 0, plan.skipPrefix + plan.takeLength <= plain.count else {
            throw BlobCryptoError.rangeOutOfBounds
        }
        return Data(plain[plan.skipPrefix ..< (plan.skipPrefix + plan.takeLength)])
    }

    // MARK: Internals

    private static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buf -> OSStatus in
            guard let ptr = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, ptr)
        }
        guard status == errSecSuccess else { throw BlobCryptoError.randomFailed }
        return data
    }

    @inline(__always)
    private static func loadLE32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    @inline(__always)
    private static func rotl32(_ v: UInt32, _ n: UInt32) -> UInt32 {
        (v << n) | (v >> (32 - n))
    }

    @inline(__always)
    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl32(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl32(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl32(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl32(s[b], 7)
    }
}
