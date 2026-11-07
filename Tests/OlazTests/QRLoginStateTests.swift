import Foundation
import Testing
@testable import Olaz

@MainActor
@Suite struct QRLoginStateTests {
    private let replacement: [String: Any] = [
        "error_code": -20,
        "error_message": "Vui lòng thử lại QR mới.",
        "data": [
            "token_id": "replacement-ticket", "qr_cnt": "http://zaloapp.com/qr/l?tk=replacement-ticket",
            "base64_qr": "replacement-image", "chk_wait_scan": "https://qr-id.zaloapp.com/polling/qr/waiting?code=replacement",
            "chk_wait_cfirm": "https://qr-id.zaloapp.com/polling/qr/pc-status?code=replacement",
            "qr_timeout": 180, "qr_retry": 3,
        ],
    ]

    @Test func replacementTicketIsNotAFatalLoginError() {
        var state = ZaloEngine.LoginState(step: .waitingScan, qrPNG: Data([1]))
        state.receivePoll(replacement)
        #expect(state.step == .generating)
        #expect(state.qrPNG == nil)
    }

    @Test func secondQRRecoversFromThePreviouslyShownFailure() {
        var state = ZaloEngine.LoginState(step: .failed("Vui lòng thử lại QR mới."), qrPNG: Data([1]))
        state.receiveQR(Data([2]), event: "qr2")
        #expect(state.step == .waitingScan)
        #expect(state.qrPNG == Data([2]))
    }

    @Test func replacementQRCanBeScannedThenConfirmed() {
        var state = ZaloEngine.LoginState(step: .waitingScan, qrPNG: Data([1]))
        state.receivePoll(replacement)
        state.receiveQR(Data([2]), event: "qr2")
        state.receivePoll(["error_code": 0, "data": ["display_name": "Test Account"]])
        #expect(state.step == .waitingConfirm(name: "Test Account", avatar: nil))
    }

    @Test func genuineServerErrorStillFails() {
        var state = ZaloEngine.LoginState(step: .waitingScan)
        state.receivePoll(["error_code": 18013, "error_message": "Login denied", "data": [:]])
        #expect(state.step == .failed("Login denied"))
    }

    @Test func errorWithoutAReplacementTicketIsNotSilentlyIgnored() {
        var state = ZaloEngine.LoginState(step: .waitingScan)
        state.receivePoll(["error_code": -20, "error_message": "Invalid QR", "data": [:]])
        #expect(state.step == .failed("Invalid QR"))
    }

    @Test(arguments: ["base64_qr", "qr_cnt", "ntk"])
    func replacementAcceptsEachSupportedImageOrTokenMarker(marker: String) {
        var state = ZaloEngine.LoginState(step: .waitingScan, qrPNG: Data([1]))
        state.receivePoll([
            "error_code": -20, "error_message": "Renew QR",
            "data": ["chk_wait_scan": "https://qr-id.zaloapp.com/polling/qr/waiting", marker: "replacement"],
        ])
        #expect(state.step == .generating)
        #expect(state.awaitingReplacementQR)
        #expect(state.qrPNG == nil)
    }

    @Test func incompleteReplacementTicketStillFails() {
        for data in [
            ["chk_wait_scan": "https://qr-id.zaloapp.com/polling/qr/waiting"],
            ["ntk": "replacement"],
            ["chk_wait_scan": "", "qr_cnt": "replacement"],
            ["chk_wait_scan": "https://qr-id.zaloapp.com/polling/qr/waiting", "base64_qr": ""],
        ] {
            var state = ZaloEngine.LoginState(step: .waitingScan)
            state.receivePoll(["error_code": -20, "error_message": "Invalid QR", "data": data])
            #expect(state.step == .failed("Invalid QR"))
            #expect(!state.awaitingReplacementQR)
        }
    }

    @Test func staleDOMSnapshotCannotRestoreTheReplacedQR() {
        var state = ZaloEngine.LoginState(step: .waitingScan, qrPNG: Data([1]))
        state.receivePoll(replacement)
        state.receiveQR(Data([1]), event: nil)
        #expect(state.step == .generating)
        #expect(state.qrPNG == nil)
        state.receiveQR(Data([2]), event: "qr2")
        #expect(state.step == .waitingScan)
        #expect(state.qrPNG == Data([2]))
    }

    @Test func ordinaryDOMSnapshotDoesNotResetConfirmationOrFailure() {
        for step in [ZaloEngine.LoginState.Step.waitingConfirm(name: "Test Account", avatar: nil), .failed("Invalid QR")] {
            var state = ZaloEngine.LoginState(step: step)
            state.receiveQR(Data([1]), event: nil)
            #expect(state.step == step)
        }
    }

    @Test func freshQRResetsExpiredState() {
        var state = ZaloEngine.LoginState(step: .expired)
        state.receiveQR(Data([1]), event: "qr")
        #expect(state.step == .waitingScan)
    }
}
