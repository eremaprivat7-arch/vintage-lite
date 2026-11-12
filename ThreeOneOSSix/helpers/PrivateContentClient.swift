import CryptoKit
import Foundation
import Security

struct PrivateContentCredentials {
    let key: String
    let device: String
}

struct PrivateContentAsset: Decodable, Identifiable {
    let id: String
    let title: String
    let category: String
    let package_id: String
    let size: Int
    let revision: String
}

struct PrivateContentError: LocalizedError {
    let code: String
    var errorDescription: String? {
        switch code {
        case "content_setup", "content_unavailable": return "Защищённое хранилище ещё не настроено. Напиши @osinxff."
        case "device_key_changed": return "Защитный ключ устройства изменился. Напиши @osinxff для проверки привязки."
        case "secure_enclave": return "Не удалось открыть защитный ключ этого iPhone. Разблокируй устройство и повтори."
        case "license_denied", "unauthorized", "session_expired": return "Нет доступа к файлам. Обнови проверку лицензии."
        case "maintenance", "update_required": return "Сейчас патч или требуется новая версия приложения."
        case "rate_limited": return "Слишком много запросов. Повтори через минуту."
        case "integrity", "stale": return "Файл обновился или проверка целостности не пройдена. Обнови список."
        default: return "Не удалось получить защищённый файл. Проверь интернет и повтори."
        }
    }
}

private final class PrivateContentTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

#if targetEnvironment(simulator)
private typealias ContentSigningKey = P256.Signing.PrivateKey
private typealias ContentAgreementKey = P256.KeyAgreement.PrivateKey
#else
private typealias ContentSigningKey = SecureEnclave.P256.Signing.PrivateKey
private typealias ContentAgreementKey = SecureEnclave.P256.KeyAgreement.PrivateKey
#endif

/// Hardware key handles stay in a device-only Keychain. Payloads are never cached to disk.
actor PrivateContentClient {
    static let shared = PrivateContentClient()
    private struct Lease { let token: String; let expires: Int; let identity: String }
    private var lease: Lease?
    private var clockOffset = 0
    private var signingKey: ContentSigningKey?
    private var agreementKey: ContentAgreementKey?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: PrivateContentTransport(), delegateQueue: nil)
    }()

    func clear() { lease = nil; signingKey = nil; agreementKey = nil }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func keyData(_ name: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VintageLite.private-content.v1",
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PrivateContentError(code: "secure_enclave")
        }
        return data
    }

    private func saveKey(_ data: Data, name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VintageLite.private-content.v1",
            kSecAttrAccount as String: name,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data
        ]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw PrivateContentError(code: "secure_enclave")
        }
    }

    private func keys() throws -> (ContentSigningKey, ContentAgreementKey) {
        if let signingKey, let agreementKey { return (signingKey, agreementKey) }
#if targetEnvironment(simulator)
        let signing: ContentSigningKey
        if let data = try keyData("sim-signing") { signing = try ContentSigningKey(rawRepresentation: data) }
        else { signing = ContentSigningKey(); try saveKey(signing.rawRepresentation, name: "sim-signing") }
        let agreement: ContentAgreementKey
        if let data = try keyData("sim-agreement") { agreement = try ContentAgreementKey(rawRepresentation: data) }
        else { agreement = ContentAgreementKey(); try saveKey(agreement.rawRepresentation, name: "sim-agreement") }
#else
        guard SecureEnclave.isAvailable,
              let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .privateKeyUsage, nil) else {
            throw PrivateContentError(code: "secure_enclave")
        }
        let signing: ContentSigningKey
        if let data = try keyData("signing") { signing = try ContentSigningKey(dataRepresentation: data) }
        else { signing = try ContentSigningKey(accessControl: control); try saveKey(signing.dataRepresentation, name: "signing") }
        let agreement: ContentAgreementKey
        if let data = try keyData("agreement") { agreement = try ContentAgreementKey(dataRepresentation: data) }
        else { agreement = try ContentAgreementKey(accessControl: control); try saveKey(agreement.dataRepresentation, name: "agreement") }
#endif
        signingKey = signing; agreementKey = agreement
        return (signing, agreement)
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "LicenseServerURL") as? String,
              let base = URL(string: value), base.scheme == "https",
              base.host == "vintage-lite-license.vintage-lite-keys.workers.dev",
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
            throw PrivateContentError(code: "content_setup")
        }
        return base.appendingPathComponent(path)
    }

    private func send(_ path: String, body: [String: String], token: String) async throws -> (Data, HTTPURLResponse) {
        let url = try endpoint(path)
        let data = try JSONEncoder().encode(body)
        let stamp = String(Int(Date().timeIntervalSince1970) + clockOffset)
        let nonce = UUID().uuidString.lowercased()
        let signing = try keys().0
        let message = ["VL1", "POST", url.path, nonce, stamp,
                       digest(Data(token.utf8)), digest(data)].joined(separator: "\n")
        let signature = try signing.signature(for: Data(message.utf8)).rawRepresentation
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(nonce, forHTTPHeaderField: "X-VL-Nonce")
        request.setValue(stamp, forHTTPHeaderField: "X-VL-Time")
        request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-VL-Signature")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (received, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, received.count <= 8 * 1024 * 1024 else {
            throw PrivateContentError(code: "integrity")
        }
        return (received, http)
    }

    private struct Failure: Decodable { let error: String; let server_time: Int? }

    private func error(_ data: Data) -> PrivateContentError {
        if let value = try? JSONDecoder().decode(Failure.self, from: data) {
            if let time = value.server_time { clockOffset = time - Int(Date().timeIntervalSince1970) }
            return PrivateContentError(code: value.error)
        }
        return PrivateContentError(code: "network")
    }

    private func access(_ credentials: PrivateContentCredentials) async throws -> String {
        let identity = digest(Data((credentials.key + ":" + credentials.device).utf8))
        if let lease, lease.identity == identity,
           lease.expires > Int(Date().timeIntervalSince1970) + clockOffset + 10 { return lease.token }
        let (signing, agreement) = try keys()
        let body = ["key": credentials.key, "device": credentials.device,
                    "app_version": VintageRelease.version, "app_build": VintageRelease.build,
                    "signing": signing.publicKey.x963Representation.base64EncodedString(),
                    "agreement": agreement.publicKey.x963Representation.base64EncodedString()]
        struct Reply: Decodable { let token: String; let expires: Int; let server_time: Int }
        for attempt in 0...1 {
            let (data, response) = try await send("api/content/session", body: body, token: "")
            if response.statusCode == 200 {
                let reply = try JSONDecoder().decode(Reply.self, from: data)
                clockOffset = reply.server_time - Int(Date().timeIntervalSince1970)
                lease = Lease(token: reply.token, expires: reply.expires, identity: identity)
                return reply.token
            }
            let failure = error(data)
            if failure.code == "clock_skew", attempt == 0 { continue }
            throw failure
        }
        throw PrivateContentError(code: "network")
    }

    private func authorized(_ path: String, body: [String: String], credentials: PrivateContentCredentials) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            let token = try await access(credentials)
            let result = try await send(path, body: body, token: token)
            if result.1.statusCode == 200 { return result }
            let failure = error(result.0)
            if result.1.statusCode == 401, attempt == 0 { lease = nil; continue }
            if failure.code == "clock_skew", attempt == 0 { continue }
            throw failure
        }
        throw PrivateContentError(code: "network")
    }

    func catalog(_ credentials: PrivateContentCredentials) async throws -> [PrivateContentAsset] {
        let (data, _) = try await authorized("api/content/catalog", body: [:], credentials: credentials)
        struct Catalog: Decodable { let assets: [PrivateContentAsset] }
        return try JSONDecoder().decode(Catalog.self, from: data).assets
    }

    func project(_ asset: PrivateContentAsset, credentials: PrivateContentCredentials) async throws -> PatchProject {
        let (_, response) = try await authorized("api/content/package", body: ["id": asset.id], credentials: credentials)
        struct Wrapped: Decodable {
            let public_key: String; let salt: String; let key: String; let revision: String
            let parts: Int; let size: Int
        }
        guard let header = response.value(forHTTPHeaderField: "X-VL-Key"),
              let metadata = Data(base64Encoded: header), metadata.count < 4096 else { throw PrivateContentError(code: "integrity") }
        let wrap = try JSONDecoder().decode(Wrapped.self, from: metadata)
        guard wrap.revision == asset.revision, wrap.size == asset.size,
              wrap.size > 0, wrap.size <= 8 * 1024 * 1024,
              wrap.parts == (wrap.size + 262143) / 262144,
              let publicData = Data(base64Encoded: wrap.public_key), publicData.count == 65,
              let salt = Data(base64Encoded: wrap.salt), salt.count == 32,
              let wrapped = Data(base64Encoded: wrap.key), wrapped.count == 60 else { throw PrivateContentError(code: "stale") }
        var cipher = Data()
        cipher.reserveCapacity(wrap.size)
        for part in 0..<wrap.parts {
            let (piece, reply) = try await authorized("api/content/chunk", body: ["id": asset.id, "revision": wrap.revision, "part": String(part)], credentials: credentials)
            guard piece.count == min(262144, wrap.size - part * 262144),
                  reply.value(forHTTPHeaderField: "X-VL-Part-SHA256") == digest(piece) else { throw PrivateContentError(code: "integrity") }
            cipher.append(piece)
        }
        guard digest(cipher) == wrap.revision else { throw PrivateContentError(code: "integrity") }
        let agreement = try keys().1
        let shared = try agreement.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: publicData))
        let info = Data(("VL-wrap-v1:" + asset.id + ":" + wrap.revision).utf8)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        var dataKey = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: wrappingKey, authenticating: info)
        defer { dataKey.resetBytes(in: 0..<dataKey.count) }
        var clear = try AES.GCM.open(AES.GCM.SealedBox(combined: cipher), using: SymmetricKey(data: dataKey),
                                     authenticating: Data(("VL-content-v1:" + asset.id).utf8))
        defer { clear.resetBytes(in: 0..<clear.count) }
        guard clear.count > 38, clear.prefix(6) == Data("VLCP1\0".utf8) else { throw PrivateContentError(code: "integrity") }
        var packageKey = Data(clear[6..<38])
        defer { packageKey.resetBytes(in: 0..<packageKey.count) }
        let package = Data(clear.dropFirst(38))
        let summary = try PatchPackageCodec.inspect(package)
        guard summary.packageID.uuidString.lowercased() == asset.package_id.lowercased() else { throw PrivateContentError(code: "integrity") }
        var project = try PatchPackageCodec.decode(package, contentKey: packageKey).project
        // Private transactions do not save the .applied replacement-file copies.
        project.isPrivate = true
        return project
    }
}
