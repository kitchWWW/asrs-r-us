import CryptoKit
import Foundation

/// AWS Signature Version 4 for a single JSON POST.
///
/// Deliberately narrow: this signs one shape of request -- a POST with a JSON
/// body to a Bedrock endpoint -- rather than being a general implementation.
/// That keeps the canonicalisation rules that actually bite (sorted lowercase
/// headers, the exact signed-header list, path escaping) in one readable place.
enum SigV4 {

    static func sign(
        request: inout URLRequest,
        payload: Data,
        service: String,
        region: String,
        credentials: AWSCredentials,
        now: Date = Date()
    ) {
        guard let url = request.url, let host = url.host else { return }

        let amzDate = dateFormatter.string(from: now)          // 20260812T044500Z
        let dateStamp = String(amzDate.prefix(8))              // 20260812

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        // Only these headers are signed. Adding an unsigned header afterwards
        // is fine; adding a *signed* one without listing it here is not.
        var signed: [(String, String)] = [
            ("content-type", request.value(forHTTPHeaderField: "Content-Type") ?? "application/json"),
            ("host", host),
            ("x-amz-date", amzDate),
        ]
        if let token = credentials.sessionToken {
            signed.append(("x-amz-security-token", token))
        }
        signed.sort { $0.0 < $1.0 }

        let signedHeaderNames = signed.map(\.0).joined(separator: ";")
        let canonicalHeaders = signed
            .map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }
            .joined()

        // Every service except S3 wants the canonical path encoded a *second*
        // time, so the `%3A` that Bedrock model IDs carry ("...-v1:0") has to
        // appear here as `%253A` while the request itself still sends `%3A`.
        // Getting this wrong fails only for model IDs containing a colon,
        // which is most of them and none of the newer aliases.
        let rawPath = url.path(percentEncoded: true)
        let canonicalPath = (rawPath.isEmpty ? "/" : rawPath)
            .addingPercentEncoding(withAllowedCharacters:
                .alphanumerics.union(CharacterSet(charactersIn: "-._~/"))) ?? rawPath

        let canonicalRequest = [
            request.httpMethod ?? "POST",
            canonicalPath,
            url.query(percentEncoded: true) ?? "",
            canonicalHeaders,
            signedHeaderNames,
            hex(SHA256.hash(data: payload)),
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for element in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: hmac(Data(element.utf8), key: key))
        }
        let signature = hex(hmac(Data(stringToSign.utf8), key: key))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaderNames), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private static func hmac(_ data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
