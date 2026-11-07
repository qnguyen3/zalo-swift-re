import Foundation
import CryptoKit

/// Rebuilds supported API queries like ctdozlite, without changing renderer-owned encryption or routing.
enum APIURLBuilder {
    static func rebuild(_ url: URL, method: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              ["zalo.me", "zaloapp.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              components.percentEncodedPath.hasPrefix("/api/"),
              let items = components.queryItems, !items.isEmpty else { return url }

        var parameters: [String: String] = [:]
        for item in items {
            // Never collapse duplicate/aliased keys or convert a bare flag into an empty value.
            guard let value = item.value,
                  parameters.updateValue(value, forKey: item.name) == nil else { return url }
        }

        if parameters["signkey"] != nil {
            guard ["wpa.zaloapp.com", "wpa.chat.zalo.me"].contains(host),
                  let rule = signingRule(path: components.percentEncodedPath, method: method.uppercased()),
                  rule.fields.isSubset(of: Set(parameters.keys)),
                  Set(parameters.keys).isSubset(of: rule.fields.union(rule.postSignFields).union(["signkey"])) else {
                return url
            }
            if rule.fields.contains("enc_ver"), parameters["enc_ver"] != "v2" { return url }
            let input = "zsecure" + rule.tag + rule.fields.sorted().map { parameters[$0]! }.joined()
            // MD5 is mandated by Zalo's wire protocol, not used as a security primitive here.
            parameters["signkey"] = Insecure.MD5.hash(data: Data(input.utf8))
                .map { String(format: "%02x", $0) }.joined()
        } else {
            let commonFields: Set<String> = ["zpw_ver", "zpw_type", "params", "type", "nretry", "ts"]
            guard parameters["zpw_ver"] != nil, parameters["zpw_type"] != nil,
                  Set(parameters.keys).isSubset(of: commonFields) else { return url }
        }

        components.percentEncodedQuery = parameters.keys.sorted().map {
            "\(encode($0))=\(encode(parameters[$0]!))"
        }.joined(separator: "&")
        return components.url ?? url
    }

    private struct SigningRule {
        let tag: String
        let fields: Set<String>
        var postSignFields: Set<String> = []
    }

    private static func signingRule(path: String, method: String) -> SigningRule? {
        switch (method, path) {
        case ("GET", "/api/login/reqqr"):
            return SigningRule(tag: "reqqr", fields: [
                "language", "client_time", "imei", "computer_name", "logged_uids",
                "self_g", "qr_form", "type", "client_version",
            ])
        case ("GET", "/api/login/getServerInfo"):
            return SigningRule(tag: "getserverinfo", fields: [
                "imei", "type", "client_version", "computer_name", "sp_mtn", "bkt",
            ])
        case ("GET", "/api/login/getLoginInfo"), ("POST", "/api/login/loginByPasswv2"):
            return SigningRule(
                tag: path == "/api/login/getLoginInfo" ? "getlogininfo" : "loginbypasswv2",
                fields: ["client_version", "enc_ver", "params", "type", "zcid", "zcid_ext"],
                postSignFields: ["ref", "nretry"])
        default:
            return nil
        }
    }

    private static func encode(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 95, 46, 126:
                return String(UnicodeScalar(byte))
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }
}
