import Foundation
import Testing
@testable import Olaz

@MainActor
@Suite struct APIURLGenerationTests {
    private func request(_ url: String, method: String = "GET") throws -> URLRequest {
        try NetworkProxy.makeRequest(from: ["url": url, "method": method])
    }

    @Test func qrRequestIsSignedAndEncodedNatively() throws {
        // Digest independently generated with Node crypto, using sorted, unescaped values.
        let input = "https://wpa.zaloapp.com/api/login/reqqr?type=30&self_g=1&qr_form=0&logged_uids=%5B%5D&language=vi&imei=device-1&computer_name=M%C3%A1y%20+%20Mac&client_version=694&client_time=1000&signkey=stale"
        let result = try request(input)
        #expect(result.url?.absoluteString == "https://wpa.zaloapp.com/api/login/reqqr?client_time=1000&client_version=694&computer_name=M%C3%A1y%20%2B%20Mac&imei=device-1&language=vi&logged_uids=%5B%5D&qr_form=0&self_g=1&signkey=06a459ccec81f97a5f541c344ab7cdb9&type=30")
    }

    @Test func serverInfoUsesItsOwnSigningTag() throws {
        let result = try request("https://wpa.zaloapp.com/api/login/getServerInfo?type=30&sp_mtn=-1&imei=device-1&computer_name=Mac&client_version=694&bkt=-1&signkey=stale")
        #expect(result.url?.absoluteString == "https://wpa.zaloapp.com/api/login/getServerInfo?bkt=-1&client_version=694&computer_name=Mac&imei=device-1&signkey=a813b3da532af098887fbdf21100e93f&sp_mtn=-1&type=30")
    }

    @Test(arguments: [
        ("getLoginInfo", "GET", "075a8632ef7f7e29e0f9b8c4b7966e70"),
        ("loginByPasswv2", "POST", "ac8ee6284d469b31ebbccfa02d1f758c"),
    ]) func encryptedLoginPreservesPayloadAndExcludesPostSignFields(endpoint: String, method: String, signature: String) throws {
        let input = "https://wpa.zaloapp.com/api/login/\(endpoint)?zcid_ext=0123456789&zcid=ABCD&type=30&params=a%2B%2Fb%3D%3D&enc_ver=v2&client_version=694&ref=https%3A%2F%2Fchat.zalo.me&nretry=2&signkey=stale"
        let result = try request(input, method: method)
        #expect(result.url?.absoluteString == "https://wpa.zaloapp.com/api/login/\(endpoint)?client_version=694&enc_ver=v2&nretry=2&params=a%2B%2Fb%3D%3D&ref=https%3A%2F%2Fchat.zalo.me&signkey=\(signature)&type=30&zcid=ABCD&zcid_ext=0123456789")
    }

    @Test func unsignedAPIQueryUsesReferenceEncodingWithoutAddingSignature() throws {
        let result = try request("https://tt-msg-wpa.zaloapp.com/api/message/sms?zpw_ver=694&zpw_type=23&params=a+/b==!'()*~&nretry=")
        #expect(result.url?.absoluteString == "https://tt-msg-wpa.zaloapp.com/api/message/sms?nretry=&params=a%2B%2Fb%3D%3D%21%27%28%29%2A~&zpw_type=23&zpw_ver=694")
    }

    @Test(arguments: [
        "https://example.com/api/login/reqqr?b=2&a=1&signkey=opaque",
        "https://zaloapp.com.evil.example/api/message/sms?zpw_ver=694&zpw_type=23",
        "https://cdn.zalo.me/photo.jpg?b=2&a=1&token=a+b",
        "https://wpa.zaloapp.com/api/login/unknown?b=2&a=1&signkey=opaque",
        "https://wpa.zaloapp.com/api/login/reqqr?type=30&signkey=opaque",
        "https://wpa.zaloapp.com/api/login/getServerInfo?type=30&sp_mtn=-1&imei=device-1&computer_name=Mac&client_version=694&bkt=-1&future=1&signkey=opaque",
        "https://wpa.zaloapp.com/api/message/sms?zpw_ver=694&zpw_type=23&zpw_type=30",
        "https://wpa.zaloapp.com/api/message/sms?zpw_ver=694&zpw_type=23&%7Apw_type=30",
        "https://wpa.zaloapp.com/api/message/sms?zpw_ver=694&zpw_type=23&params",
        "https://wpa.zaloapp.com/api/message/sms?zpw_ver=694&zpw_type=23&token=opaque",
        "https://wpa.zaloapp.com/api/message/sms",
        "http://wpa.zaloapp.com/api/message/sms?zpw_ver=694&zpw_type=23",
        "https://user:password@wpa.zaloapp.com/api/message/sms?zpw_ver=694&zpw_type=23",
        "https://wpa.zaloapp.com:8443/api/message/sms?zpw_ver=694&zpw_type=23",
        "https://qr-id.zaloapp.com/polling/qr/wait?zpw_ver=694&zpw_type=23",
    ]) func unsupportedURLsAreUntouched(input: String) throws {
        #expect(try request(input).url?.absoluteString == input)
    }

    @Test func unsupportedLoginMethodsPathsAndVersionsAreUntouched() throws {
        let input = "https://wpa.zaloapp.com/api/login/getLoginInfo?zcid_ext=0123456789&zcid=ABCD&type=30&params=a%2B%2Fb%3D%3D&enc_ver=v2&client_version=694&signkey=opaque"
        #expect(try request(input, method: "POST").url?.absoluteString == input)
        for changed in [
            input.replacingOccurrences(of: "getLoginInfo", with: "getlogininfo"),
            input.replacingOccurrences(of: "/api/login/", with: "/api%2Flogin/"),
            input.replacingOccurrences(of: "enc_ver=v2", with: "enc_ver=v3"),
            input.replacingOccurrences(of: "&signkey=opaque", with: ""),
            input + "&signkey=duplicate",
        ] {
            #expect(try request(changed).url?.absoluteString == changed)
        }
    }

    @Test func encodingDecodesExactlyOnceAndPreservesFragments() throws {
        let result = try request("https://tt-msg-wpa.zaloapp.com/api/message/sms?zpw_ver=694&zpw_type=23&params=%252B%2B%2F%3D#keep")
        #expect(result.url?.absoluteString == "https://tt-msg-wpa.zaloapp.com/api/message/sms?params=%252B%2B%2F%3D&zpw_type=23&zpw_ver=694#keep")
    }

    @Test func requestAssemblyPreservesMethodHeadersBodyAndTimeout() throws {
        let body = "params=a%2B%2Fb%3D%3D"
        let result = try NetworkProxy.makeRequest(from: [
            "url": "https://tt-msg-wpa.zaloapp.com/api/message/sms?zpw_ver=694&zpw_type=23",
            "method": "POST", "headers": ["Content-Type": "application/x-www-form-urlencoded", "X-Test": "value"],
            "timeout": 1250,
            "body": ["kind": "text", "text": body],
        ])
        #expect(result.url?.query == "zpw_type=23&zpw_ver=694")
        #expect(result.httpMethod == "POST")
        #expect(result.httpBody == Data(body.utf8))
        #expect(result.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(result.value(forHTTPHeaderField: "X-Test") == "value")
        #expect(result.timeoutInterval == 1.25)
    }

    @Test func signedLoginRebuildsOnlyOnKnownAuthHosts() throws {
        let query = "type=30&sp_mtn=-1&imei=device-1&computer_name=Mac&client_version=694&bkt=-1&signkey=stale"
        for host in ["wpa.zaloapp.com", "wpa.chat.zalo.me"] {
            let result = try request("https://\(host)/api/login/getServerInfo?\(query)")
            #expect(result.url?.absoluteString == "https://\(host)/api/login/getServerInfo?bkt=-1&client_version=694&computer_name=Mac&imei=device-1&signkey=a813b3da532af098887fbdf21100e93f&sp_mtn=-1&type=30")
        }
        for host in ["tt-msg-wpa.zaloapp.com", "qr-id.zaloapp.com"] {
            let input = "https://\(host)/api/login/getServerInfo?\(query)"
            #expect(try request(input).url?.absoluteString == input)
        }
    }

    @Test func missingURLIsRejected() {
        #expect(throws: URLError.self) {
            try NetworkProxy.makeRequest(from: [:])
        }
    }
}
