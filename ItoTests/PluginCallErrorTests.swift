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
        (.other, .reported)
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

    @Test(arguments: [
        ItoError.wasmTrap("unreachable"),
        .memoryOutOfBounds(offset: 1, length: 2, memorySize: 3),
        .invalidDescriptor(id: 7)
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
    }

    @Test func aWebViewFailureSaysSo() {
        let error = PluginCallError(.hostModuleError(domain: "webview", message: "Timed out"))

        #expect(error == PluginCallError(kind: .host, message: "The source's web page failed: Timed out"))
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

struct PluginImageTypeTests {
    @Test(arguments: [
        ([0xFF, 0xD8, 0xFF, 0xE0], "image/jpeg"),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "image/png"),
        (Array("GIF89a".utf8), "image/gif"),
        (Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8), "image/webp"),
        ([0, 0, 0, 0x1C] + Array("ftypavif".utf8), "image/avif"),
        ([0, 0, 0, 0x18] + Array("ftypheic".utf8), "image/heic")
    ] as [([UInt8], String)])
    func pluginImageBytesGetTheirRealType(bytes: [UInt8], type: String) {
        #expect(PluginDataLoader.imageMIMEType(of: Data(bytes)) == type)
    }

    @Test func unknownBytesGetNoType() {
        #expect(PluginDataLoader.imageMIMEType(of: Data("<html>".utf8)) == nil)
    }
}
