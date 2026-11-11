import Foundation
import CommonCrypto

// MARK: - AES-128-CBC + PKCS7 + base64（与 ios-server app/crypto.py 字节级兼容）
//
// ios-server 是一个 AES 加密代理：客户端把 adhead 和 {"data": <payload>} 各自
// AES 加密后 base64，分别放进 Authorization 头和 body。本类型复刻服务端 crypto.py
// 的 encrypt_to_b64 / decrypt_b64，保证客户端密文能被服务端正确解密（反之亦然）。
//
// CryptoKit 只支持 GCM、不支持 CBC，因此用 CommonCrypto 的 CCCrypt。
// 已用 ios-server app/crypto.py 产出的密文做跨实现一致性验证（见联调记录）。

public enum TianxAES {
    public enum Error: Swift.Error {
        case invalidKeyLength       // key 必须 16 字节（AES-128）
        case invalidIVLength        // iv 必须 16 字节
        case cryptFailed            // CCCrypt 返回非 0
        case invalidBase64          // 解密入参不是合法 base64
        case jsonFailed             // JSON 序列化/反序列化失败
    }

    /// 把任意可 JSON 序列化对象加密为 base64 字符串（对齐 server encrypt_to_b64）。
    public static func encryptToBase64(_ object: Any, key: String, iv: String) throws -> String {
        let keyBytes = Array(key.utf8)
        let ivBytes = Array(iv.utf8)
        guard keyBytes.count == kCCKeySizeAES128 else { throw Error.invalidKeyLength }
        guard ivBytes.count == kCCBlockSizeAES128 else { throw Error.invalidIVLength }
        let plain: Data
        do {
            plain = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch { throw Error.jsonFailed }
        let cipher = try crypt(data: plain, key: keyBytes, iv: ivBytes, encrypt: true)
        return cipher.base64EncodedString()
    }

    /// 解密 base64 密文为已解析的 JSON 对象（对齐 server decrypt_b64）。
    public static func decryptBase64(_ base64String: String, key: String, iv: String) throws -> Any {
        let keyBytes = Array(key.utf8)
        let ivBytes = Array(iv.utf8)
        guard keyBytes.count == kCCKeySizeAES128 else { throw Error.invalidKeyLength }
        guard ivBytes.count == kCCBlockSizeAES128 else { throw Error.invalidIVLength }
        guard let cipher = Data(base64Encoded: base64String) else { throw Error.invalidBase64 }
        let plain = try crypt(data: cipher, key: keyBytes, iv: ivBytes, encrypt: false)
        do {
            return try JSONSerialization.jsonObject(with: plain)
        } catch { throw Error.jsonFailed }
    }

    /// 解密 base64 密文为原始明文 Data（响应按需解密时用；当前代理响应是明文，暂不用）。
    public static func decryptBase64ToData(_ base64String: String, key: String, iv: String) throws -> Data {
        let keyBytes = Array(key.utf8)
        let ivBytes = Array(iv.utf8)
        guard keyBytes.count == kCCKeySizeAES128 else { throw Error.invalidKeyLength }
        guard ivBytes.count == kCCBlockSizeAES128 else { throw Error.invalidIVLength }
        guard let cipher = Data(base64Encoded: base64String) else { throw Error.invalidBase64 }
        return try crypt(data: cipher, key: keyBytes, iv: ivBytes, encrypt: false)
    }

    private static func crypt(data: Data, key: [UInt8], iv: [UInt8], encrypt: Bool) throws -> Data {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var written = 0
        let status = buffer.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            data.withUnsafeBytes { inBytes in
                CCCrypt(encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        key, key.count,
                        iv,
                        inBytes.baseAddress, data.count,
                        outBytes.baseAddress, bufferSize, &written)
            }
        }
        guard status == kCCSuccess else { throw Error.cryptFailed }
        return buffer.prefix(written)
    }
}
