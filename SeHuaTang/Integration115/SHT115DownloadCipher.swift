import Foundation
import Security

/// 115 m115 RSA protocol (public exponent for both directions), not generic RSA decryption.
/// Protocol reference: ChenyangGao/p115client modules/p115rsacipher.
enum SHT115DownloadCipher {
    enum Failure: Error { case malformed, key, rsa }
    static let modulus = "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b8602136477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad6338c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
    static let table = hex("f0e569aebfdcbf8a1a45e8be7da673b8de8fe7c445da86c49b648b146ab4f1aa3801359e26692c86006b4fa5363462a62a966818f24afdbd6b978f4d8f8913b76c8e93ed0e0d483ed72f88d8fefe7e8650954fd1eb832634db667b9c7e9d7a8132eab633de3aa95934663baaba816048b9d5819cf86c8477ff5478265fbee81e369f34805c452c9b76d51b8fccc3b8f5")
    static func hex(_ s: String) -> [UInt8] {
        let chars = Array(s); return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
    }
    static func xor(_ bytes: [UInt8], _ key: [UInt8]) -> [UInt8] {
        let prefix = bytes.count & 3
        return bytes.enumerated().map { i, b in b ^ key[i < prefix ? i : (i-prefix) % key.count] }
    }
    static func transform(_ block: [UInt8]) throws -> [UInt8] {
        // DER RSAPublicKey: positive modulus, public exponent 65537.
        let der = Data([0x30,0x81,0x89,0x02,0x81,0x81,0] + hex(modulus) + [0x02,0x03,0x01,0x00,0x01])
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 1024] as CFDictionary, &error) else { throw Failure.key }
        guard let result = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, Data(block) as CFData, &error) else { throw Failure.rsa }
        return Array(result as Data)
    }
    static func encrypt(_ data: Data) throws -> String {
        let short: [UInt8] = [0x8d,0xa5,0xa5,0x8d]
        let long: [UInt8] = [0x78,0x06,0xad,0x4c,0x33,0x86,0x5d,0x18,0x4c,0x01,0x3f,0x46]
        let plain = Array(repeating: UInt8(0), count: 16) + xor(Array(xor(Array(data), short).reversed()), long)
        var output = [UInt8]()
        for offset in stride(from: 0, to: plain.count, by: 117) {
            let chunk = Array(plain[offset..<min(offset+117, plain.count)])
            output += try transform([0] + Array(repeating: UInt8(2), count: 126-chunk.count) + [0] + chunk)
        }
        return Data(output).base64EncodedString()
    }
    static func decrypt(_ text: String) throws -> Data {
        guard let data = Data(base64Encoded: text), !data.isEmpty, data.count % 128 == 0 else { throw Failure.malformed }
        let input = Array(data); var plain = [UInt8]()
        for offset in stride(from: 0, to: input.count, by: 128) {
            let block = try transform(Array(input[offset..<offset+128]))
            guard block[0] == 0, [1,2].contains(block[1]), let end = block[2...].firstIndex(of: 0), end >= 10 else { throw Failure.malformed }
            plain += block[(end+1)...]
        }
        guard plain.count >= 16 else { throw Failure.malformed }
        var key = [UInt8]()
        for i in 0..<12 {
            let sum: UInt8 = plain[i] &+ table[12 * i]
            let value: UInt8 = table[12 * (11 - i)] ^ sum
            key.append(value)
        }
        let stage = xor(Array(plain.dropFirst(16)), key)
        let reversed = Array(stage.reversed())
        return Data(xor(reversed, [0x8d,0xa5,0xa5,0x8d]))
    }
}
