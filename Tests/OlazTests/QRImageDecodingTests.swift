import AppKit
import Foundation
import Testing
@testable import Olaz

@MainActor
@Suite struct QRImageDecodingTests {
    // Official self-generated QR images use encodeURIComponent(svg), not Base64.
    private let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><rect width=\"100\" height=\"100\" fill=\"black\"/></svg>"
    private let svgURL = "data:image/svg+xml;utf8,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%22100%22%20height%3D%22100%22%3E%3Crect%20width%3D%22100%22%20height%3D%22100%22%20fill%3D%22black%22%2F%3E%3C%2Fsvg%3E"

    @Test func percentEncodedSVGIsDecodedAndRenderable() throws {
        let data = try #require(ZaloEngine.decodeDataURL(svgURL))
        #expect(data == Data(svg.utf8))
        let image = try #require(NSImage(data: data))
        #expect(image.size == NSSize(width: 100, height: 100))
    }

    @Test func svgReplacementCanLeaveTheGeneratingState() throws {
        var state = ZaloEngine.LoginState(step: .waitingScan, qrPNG: Data([1]))
        state.receivePoll([
            "error_code": -20, "error_message": "Vui lòng thử lại QR mới.",
            "data": ["qr_cnt": "replacement-ticket", "chk_wait_scan": "https://qr-id.zaloapp.com/polling/qr/waiting"],
        ])
        #expect(state.step == .generating)
        let imageData = try #require(ZaloEngine.decodeDataURL(svgURL))
        state.receiveQR(imageData, event: "qr2")
        #expect(state.step == .waitingScan)
        #expect(!state.awaitingReplacementQR)
        #expect(state.qrPNG.flatMap(NSImage.init(data:)) != nil)
    }

    @Test func base64ImagesAreStillDecodedAsBytes() {
        #expect(ZaloEngine.decodeDataURL("data:image/png;base64,AQID") == Data([1, 2, 3]))
        #expect(ZaloEngine.decodeDataURL("data:image/svg+xml;base64,PHN2Zy8+") == Data("<svg/>".utf8))
    }

    @Test func percentEscapesAreDecodedOnceWithoutFormDecoding() {
        #expect(ZaloEngine.decodeDataURL("data:text/plain,QR%252B+%E1%BB%87") == Data("QR%2B+ệ".utf8))
        #expect(ZaloEngine.decodeDataURL("data:image/png;base64,%2B%2F8%3D") == Data([251, 255]))
    }

    @Test(arguments: ["https://example.com/image.png", "data:image/png;base64", "data:image/svg+xml;utf8,%GG", "data:image/png;base64,not-base64!", "data:image/png;base64,"])
    func malformedImageURLsAreRejected(input: String) {
        #expect(ZaloEngine.decodeDataURL(input) == nil)
    }
}
