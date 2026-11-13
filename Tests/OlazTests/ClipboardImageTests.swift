import AppKit
import Testing
@testable import Olaz

@MainActor
struct ClipboardImageTests {
    @Test func imagePasteIsAcceptedByPlainTextComposer() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        board.setData(try #require(bitmap.representation(using: .png, properties: [:])), forType: .png)
        let field = ComposerTextView.FieldTextView()
        field.isRichText = false
        field.importsGraphics = false
        field.string = "bản nháp"
        // Negative control: the existing plain-text field cannot consume this exact PNG.
        #expect(!field.readSelection(from: board))
        var received: [NSImage] = []
        field.onPasteImages = { received = $0 }
        #expect(field.readSelection(from: board))
        #expect(received.count == 1)
        #expect(field.string == "bản nháp")
    }

    @Test func pasteCommandAndMenuAcceptTIFFWithoutChangingDraftOrMentions() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        board.setData(try #require(image.tiffRepresentation), forType: .tiff)
        let field = ComposerTextView.FieldTextView()
        field.isRichText = false
        field.importsGraphics = false
        field.pasteboard = board
        ComposerTextView.setContent(field, text: "@An chào", mentions: [Mention(uid: "7", pos: 0, len: 3)])
        field.setSelectedRange(NSRange(location: 4, length: 4))
        var received: [NSImage] = []
        field.onPasteImages = { received = $0 }
        let item = NSMenuItem(title: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(field.validateUserInterfaceItem(item))
        field.paste(nil)
        #expect(received.count == 1)
        #expect(field.string == "@An chào")
        #expect(field.selectedRange() == NSRange(location: 4, length: 4))
        #expect((field.textStorage?.attribute(.zaloMention, at: 0, effectiveRange: nil) as? MentionToken)?.uid == "7")
    }

    @Test func plainTextStillPastesAtSelection() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("xin chào", forType: .string)
        let field = ComposerTextView.FieldTextView()
        field.isRichText = false
        field.string = "abc"
        field.setSelectedRange(NSRange(location: 1, length: 1))
        var imagePastes = 0
        field.onPasteImages = { _ in imagePastes += 1 }
        #expect(field.readSelection(from: board))
        #expect(field.string == "axin chàoc")
        #expect(imagePastes == 0)
    }

    @Test func finderImageFilesBecomePNGAndKeepTarget() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = [directory.appendingPathComponent("one.png"), directory.appendingPathComponent("two.png")]
        for url in urls { try data.write(to: url) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects(urls as [NSURL])
        let selection = ClipboardImages(conversationId: "original-chat", conversationName: "An", images: ClipboardImages.read(from: board))
        #expect(selection.images.count == 2)
        board.clearContents()
        board.setString("clipboard changed", forType: .string)
        let pick = try selection.writeFiles()
        defer { try? FileManager.default.removeItem(at: pick.directory) }
        #expect(selection.conversationId == "original-chat")
        #expect(pick.files.count == 2)
        for url in pick.files {
            let written = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
            #expect(written.pixelsWide == 2 && written.pixelsHigh == 3)
        }
    }

    @Test func cmdVPastesImageWhenListOrWindowHasFocus() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        board.setData(try #require(image.tiffRepresentation), forType: .tiff)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let sidebarDummy = NSControl(frame: NSRect(x: 0, y: 0, width: 120, height: 200))
        let field = ComposerTextView.FieldTextView(frame: NSRect(x: 120, y: 0, width: 200, height: 40))
        field.isEditable = true
        field.isRichText = false
        field.importsGraphics = false
        field.pasteboard = board
        var received: [NSImage] = []
        field.onPasteImages = { received = $0 }
        root.addSubview(sidebarDummy)
        root.addSubview(field)
        window.contentView = root
        window.makeFirstResponder(sidebarDummy)

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        #expect(window.performKeyEquivalent(with: event))
        #expect(received.count == 1)
        #expect(window.firstResponder === field)
    }

    @Test func stagedImagesStageRemoveAndTakePerConversation() {
        let engine = ZaloEngine()
        let first = NSImage(size: NSSize(width: 4, height: 4))
        let second = NSImage(size: NSSize(width: 8, height: 8))
        engine.stageImages([first, second], in: "conv-1")
        #expect(engine.stagedImages["conv-1"]?.count == 2)
        #expect(engine.stagedImages["conv-2"] == nil)

        if let firstId = engine.stagedImages["conv-1"]?.first?.id {
            engine.removeStagedImage(firstId, in: "conv-1")
        }
        #expect(engine.stagedImages["conv-1"]?.count == 1)

        let taken = engine.takeStagedImages(for: "conv-1")
        #expect(taken.count == 1)
        #expect(engine.stagedImages["conv-1"] == nil)

        engine.restoreStagedImages(taken, in: "conv-1")
        #expect(engine.stagedImages["conv-1"]?.count == 1)
    }
}
