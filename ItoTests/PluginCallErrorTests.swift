import Foundation
import Testing
import ito_runner
@testable import Ito

struct PluginCallErrorTests {
    @Test func aPluginsOwnMessageIsShownWithoutTheSDKPrefix() {
        let error = PluginCallError(.pluginFailed(function: "get_home", reason: "Host error: Add your server URL"))

        #expect(error == PluginCallError(kind: .reported, message: "Add your server URL"))
        #expect(error.localizedDescription == "Add your server URL")
    }

    @Test func otherReasonsAreShownAsThePluginGaveThem() {
        let error = PluginCallError(.pluginFailed(function: "get_home", reason: "Network error: timed out"))

        #expect(error.message == "Network error: timed out")
    }

    @Test func aFailureWithoutAReasonGetsAGenericMessage() {
        let error = PluginCallError(.pluginFailed(function: "get_manga_list", reason: nil))

        #expect(error == PluginCallError(kind: .reported, message: "The source couldn't complete this request."))
    }

    @Test(arguments: [
        (PluginErrorCategory.needsSetup, PluginCallError.Kind.needsSettings),
        (.unauthorized, .needsSettings),
        (.network, .reported),
        (.server, .reported),
        (.notFound, .reported),
        (.other, .reported),
        (.needsLogin, .needsLogin)
    ])
    func failuresTheSettingsCanFixPointThere(_ category: PluginErrorCategory, _ kind: PluginCallError.Kind) {
        let error = PluginCallError(.pluginFailed(function: "get_home", reason: "Add your server URL", category: category))

        #expect(error == PluginCallError(kind: kind, message: "Add your server URL"))
    }

    @Test func aDataFormatFailureIsAnIncompatibilityWhateverItsCategory() {
        let error = PluginCallError(.pluginFailed(
            function: "get_home", reason: "Serialization error: value too large", category: .needsSetup
        ))
        #expect(error.kind == .incompatible)
    }

    @Test func aSettingsFailureWithoutAReasonGetsTheGenericMessage() {
        let error = PluginCallError(.pluginFailed(function: "get_home", reason: nil, category: .needsSetup))
        #expect(error == PluginCallError(kind: .needsSettings, message: "The source couldn't complete this request."))
    }

    @Test func aSignInRequestWithoutAReasonAsksTheUserToSignIn() {
        for reason in [nil, ""] as [String?] {
            let error = PluginCallError(.pluginFailed(function: "get_home", reason: reason, category: .needsLogin))
            #expect(error == PluginCallError(kind: .needsLogin, message: "Sign in to this source to continue."))
        }
        let own = PluginCallError(.pluginFailed(function: "get_home", reason: "Host error: Log in first", category: .needsLogin))
        #expect(own == PluginCallError(kind: .needsLogin, message: "Log in first"))
    }

    @Test(arguments: [
        ItoError.wasmTrap("unreachable"),
        .memoryOutOfBounds(offset: 1, length: 2, memorySize: 3)
    ])
    func aTrapOrBadMemoryAccessIsACrash(_ runnerError: ItoError) {
        #expect(PluginCallError(runnerError).kind == .crashed)
    }

    @Test(arguments: [
        "Deserialization error: unexpected end of input",
        "Serialization error: value too large",
        "Postcard decoding error in get_manga_update: bad varint"
    ])
    func aPluginThatCannotReadOrWriteTheDataIsAnIncompatibility(_ reason: String) {
        #expect(PluginCallError(.pluginFailed(function: "get_manga_update", reason: reason)).kind == .incompatible)
    }

    @Test func undecodableDataIsAnIncompatibility() {
        #expect(PluginCallError(.postcardDecodingError("Unexpected end of data")).kind == .incompatible)
        let invalidControls = ItoError.controlContractViolation(
            function: "get_settings_form", violation: .init(.signature)
        )
        #expect(PluginCallError(invalidControls).kind == .incompatible)
    }

    @Test func aCatalogContractViolationIsAnIncompatibilityThatNeverShowsTheRule() {
        let error = PluginCallError(.catalogContractViolation(function: "get_manga_list", violation: .init(.duplicateKey)))

        #expect(error == PluginCallError(
            kind: .incompatible, message: "The source sent something this version of Ito can't read. Update the source or Ito."
        ))
    }

    @Test func aChapterEditionsViolationIsAnIncompatibilityThatNeverShowsTheRule() {
        let error = PluginCallError(.chapterEditionsViolation(
            function: "get_chapter_editions", violation: .init(.requestEntryKind)
        ))

        #expect(error == PluginCallError(
            kind: .incompatible, message: "The source sent something this version of Ito can't read. Update the source or Ito."
        ))
    }

    @Test func aPluginReportedContractViolationIsAnIncompatibilityWhateverItsReason() {
        let error = PluginCallError(.pluginFailed(
            function: "get_manga_list", reason: "duplicate.key", category: .contractViolation
        ))

        #expect(error == PluginCallError(
            kind: .incompatible, message: "The source sent something this version of Ito can't read. Update the source or Ito."
        ))
        #expect(!error.message.contains("duplicate.key"))
    }

    @Test func aWebViewFailureSaysSo() {
        let error = PluginCallError(.hostModuleError(domain: "webview", message: "Timed out"))

        #expect(error == PluginCallError(kind: .host, message: "The source's web page failed: Timed out"))
    }

    @Test func anOfflinePolicyOutcomeAsksTheUserToCheckTheConnection() {
        for outcome in [HostNetworkPolicyOutcome.deferred(.offline), .deferred(.unknownPath)] {
            #expect(PluginCallError(.networkPolicy(outcome)) == PluginCallError(
                kind: .host, message: "Check your internet connection or try again later."
            ))
        }
    }

    @Test func anAuthorizationPolicyOutcomeSendsTheUserToTheSourceSettings() {
        #expect(PluginCallError(.networkPolicy(.sourceAuthorizationFailure)) == PluginCallError(
            kind: .needsSettings, message: "The server or account settings changed, or are incomplete."
        ))
    }

    @Test func otherPolicyOutcomesAndRunnerReloadsAreHostErrorsWithTheGenericMessage() {
        let errors: [ItoError] = [
            .networkPolicy(.deferred(.expensivePath)),
            .networkPolicy(.deferred(.constrainedPath)),
            .networkPolicy(.deferred(.policyChanged)),
            .networkPolicy(.foregroundPermissionRequired),
            .networkPolicy(.hardUserBlocked),
            .reloadDuringActiveExport,
            .pluginReloaded
        ]
        for error in errors {
            #expect(PluginCallError(error) == PluginCallError(
                kind: .host, message: "The source couldn't complete this request."
            ))
        }
    }

    @Test func aHostCallTimeoutIsATypedHostErrorNotACrashOrServerError() {
        let net = PluginCallError(.hostCallTimedOut(.net))
        let webview = PluginCallError(.hostCallTimedOut(.webview))

        #expect(net == PluginCallError(kind: .host, message: "The source took too long to respond. Try again."))
        #expect(webview == PluginCallError(
            kind: .host, message: "The source's web page took too long to respond. Try again."
        ))
        // Not `.crashed`: a timed-out call must never make screens retire the runner.
        #expect(net.kind != .crashed && webview.kind != .crashed)
    }

    @Test func errorsThatDidNotComeFromTheRunnerPassThrough() {
        #expect(PluginCallError.wrapping(CancellationError()) is CancellationError)
        #expect((PluginCallError.wrapping(URLError(.timedOut)) as? URLError)?.code == .timedOut)
    }

    @Test func aPluginCallTurnsRunnerErrorsIntoPluginCallErrors() async {
        await #expect(throws: PluginCallError(kind: .reported, message: "Refused path")) {
            try await pluginCall {
                throw ItoError.pluginFailed(function: "handle_image", reason: "Host error: Refused path")
            }
        }
    }
}

struct ImageSignatureTests {
    @Test(arguments: [
        ([0xFF, 0xD8, 0xFF, 0xE0], "image/jpeg", "jpg"),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "image/png", "png"),
        (Array("GIF89a".utf8), "image/gif", "gif"),
        (Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8), "image/webp", "webp"),
        ([0, 0, 0, 0x1C] + Array("ftypavif".utf8), "image/avif", "avif"),
        ([0, 0, 0, 0x18] + Array("ftypheic".utf8), "image/heic", "heic")
    ] as [([UInt8], String, String)])
    func imageBytesGetTheirRealTypeAndExtension(bytes: [UInt8], type: String, fileExtension: String) {
        #expect(ImageSignature.detect(Data(bytes)) == ImageSignature.Detection(fileExtension: fileExtension, mediaType: type))
    }

    @Test func anErrorPageIsNotAnImage() {
        #expect(ImageSignature.detect(Data("<html>error page</html>".utf8)) == nil)
    }
}
