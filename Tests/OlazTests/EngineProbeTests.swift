import AppKit
import Testing
@testable import Olaz

/// `--engine-probe` exports the QR for external tools through `OLAZ_QR_OUT`. It must accept both the
/// server's base64 PNG and the renderer's percent-encoded SVG (trusted-device / multi-layer QR).
@MainActor
@Suite struct EngineProbeQRExport {
    private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    @Test func base64PNGPassesThrough() throws {
        let png = Data(pngSignature + [0x01, 0x02, 0x03])
        let exported = try #require(EngineProbe.exportedQRData(from: "data:image/png;base64," + png.base64EncodedString()))
        #expect(exported == png)
    }

    @Test func percentEncodedSVGIsRasterizedToPNG() throws {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="40" height="40" viewBox="0 0 40 40"><rect width="100%" height="100%" fill="white"/><rect x="10" y="10" width="20" height="20" fill="black"/></svg>"#
        let encoded = try #require(svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let exported = try #require(EngineProbe.exportedQRData(from: "data:image/svg+xml;utf8," + encoded))

        #expect(Array(exported.prefix(pngSignature.count)) == pngSignature)
        #expect(NSImage(data: exported) != nil)
    }

    @Test func rejectsNonDataURLs() {
        #expect(EngineProbe.exportedQRData(from: "https://example.com/qr.png") == nil)
    }
}
