import AppKit
import Foundation
import UniformTypeIdentifiers

/// Utilities for managing chat media and files (saving to ~/Downloads/Olaz, opening, revealing in Finder, Save As).
enum ChatFiles {
    /// Dedicated download folder: ~/Downloads/Olaz
    static var downloadsDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let dir = downloads.appendingPathComponent(AppBrand.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func timestampString(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(for: date) ?? "\(Int(date.timeIntervalSince1970))"
    }

    static func sanitizeFilename(_ name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if base.isEmpty { base = "Tệp" }
        return base
    }

    /// Stages a file into ~/Downloads/Olaz with a friendly display name.
    static func stageToDownloads(_ source: URL, displayName: String) throws -> URL {
        let fm = FileManager.default
        let safeName = sanitizeFilename(displayName)
        let target = downloadsDirectory.appendingPathComponent(safeName)

        if fm.fileExists(atPath: target.path) {
            let srcSize = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
            let targetSize = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
            if srcSize == targetSize && srcSize > 0 {
                return target
            }
        }

        try? fm.removeItem(at: target)
        do {
            try fm.copyItem(at: source, to: target)
            return target
        } catch {
            return source
        }
    }

    // MARK: - Generic Files

    /// Prepares the file in ~/Downloads/Olaz with its original display name.
    static func localFile(for url: URL, displayName: String) async throws -> URL {
        let cached = try await MediaLoader.shared.localFile(for: url)
        let staged = try stageToDownloads(cached, displayName: displayName)
        MediaLoader.applyQuarantine(to: staged, origin: url)
        return staged
    }

    /// Shows a received file in Finder (downloading first if needed).
    @MainActor
    @discardableResult
    static func showInFinder(url: URL, displayName: String) async -> URL? {
        do {
            let file = try await localFile(for: url, displayName: displayName)
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return file
        } catch {
            return nil
        }
    }

    /// Opens the file with the default app (or Finder if executable).
    @MainActor
    @discardableResult
    static func open(url: URL, displayName: String) async -> URL? {
        do {
            let file = try await localFile(for: url, displayName: displayName)
            if FileCard.mayExecute(file, displayName: displayName) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                NSWorkspace.shared.open(file)
            }
            return file
        } catch {
            return nil
        }
    }

    // MARK: - Photos

    @MainActor
    @discardableResult
    static func showPhotoInFinder(url: URL?, conversationId: String, messageId: String, date: Date, engine: ZaloEngine) async -> URL? {
        do {
            let local = try await resolvePhotoFile(url: url, conversationId: conversationId, messageId: messageId, engine: engine)
            let ext = local.pathExtension.isEmpty ? "jpg" : local.pathExtension
            let name = "Zalo_\(timestampString(for: date)).\(ext)"
            let staged = try stageToDownloads(local, displayName: name)
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            return staged
        } catch {
            return nil
        }
    }

    @MainActor
    static func savePhotoAs(url: URL?, conversationId: String, messageId: String, date: Date, engine: ZaloEngine) async {
        do {
            let local = try await resolvePhotoFile(url: url, conversationId: conversationId, messageId: messageId, engine: engine)
            let ext = local.pathExtension.isEmpty ? "jpg" : local.pathExtension
            let name = "Zalo_\(timestampString(for: date)).\(ext)"
            let staged = try stageToDownloads(local, displayName: name)
            await saveAs(file: staged, displayName: name)
        } catch {}
    }

    private static func resolvePhotoFile(url: URL?, conversationId: String, messageId: String, engine: ZaloEngine) async throws -> URL {
        if let url, url.query?.contains("e2esession") != true {
            if let cached = try? await MediaLoader.shared.localFile(for: url) {
                return cached
            }
        }
        if case .file(let file) = await engine.resolveMedia(conversationId: conversationId, messageId: messageId, kind: .photo, force: false) {
            return file
        }
        if let url {
            return try await MediaLoader.shared.localFile(for: url)
        }
        throw URLError(.cannotOpenFile)
    }

    // MARK: - Videos

    @MainActor
    @discardableResult
    static func showVideoInFinder(url: URL?, localFile: URL? = nil, conversationId: String, messageId: String, date: Date, engine: ZaloEngine) async -> URL? {
        do {
            let local: URL
            if let localFile, FileManager.default.fileExists(atPath: localFile.path) {
                local = localFile
            } else {
                local = try await resolveVideoFile(url: url, conversationId: conversationId, messageId: messageId, engine: engine)
            }
            let ext = local.pathExtension.isEmpty ? "mp4" : local.pathExtension
            let name = "Video_\(timestampString(for: date)).\(ext)"
            let staged = try stageToDownloads(local, displayName: name)
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            return staged
        } catch {
            return nil
        }
    }

    @MainActor
    static func saveVideoAs(url: URL?, localFile: URL? = nil, conversationId: String, messageId: String, date: Date, engine: ZaloEngine) async {
        do {
            let local: URL
            if let localFile, FileManager.default.fileExists(atPath: localFile.path) {
                local = localFile
            } else {
                local = try await resolveVideoFile(url: url, conversationId: conversationId, messageId: messageId, engine: engine)
            }
            let ext = local.pathExtension.isEmpty ? "mp4" : local.pathExtension
            let name = "Video_\(timestampString(for: date)).\(ext)"
            let staged = try stageToDownloads(local, displayName: name)
            await saveAs(file: staged, displayName: name)
        } catch {}
    }

    private static func resolveVideoFile(url: URL?, conversationId: String, messageId: String, engine: ZaloEngine) async throws -> URL {
        if case .file(let file) = await engine.resolveMedia(conversationId: conversationId, messageId: messageId, kind: .video, force: false) {
            return file
        }
        if let url {
            return try await MediaLoader.shared.localFile(for: url)
        }
        throw URLError(.cannotOpenFile)
    }

    // MARK: - Voice

    @MainActor
    @discardableResult
    static func showVoiceInFinder(url: URL, date: Date) async -> URL? {
        do {
            let local = try await MediaLoader.shared.localFile(for: url)
            let ext = local.pathExtension.isEmpty ? "m4a" : local.pathExtension
            let name = "Voice_\(timestampString(for: date)).\(ext)"
            let staged = try stageToDownloads(local, displayName: name)
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            return staged
        } catch {
            return nil
        }
    }

    @MainActor
    static func saveVoiceAs(url: URL, date: Date) async {
        do {
            let local = try await MediaLoader.shared.localFile(for: url)
            let ext = local.pathExtension.isEmpty ? "m4a" : local.pathExtension
            let name = "Voice_\(timestampString(for: date)).\(ext)"
            let staged = try stageToDownloads(local, displayName: name)
            await saveAs(file: staged, displayName: name)
        } catch {}
    }

    // MARK: - Save Dialog & Clipboard

    @MainActor
    static func saveAs(url: URL, displayName: String, window: NSWindow? = nil) async {
        do {
            let file = try await localFile(for: url, displayName: displayName)
            await saveAs(file: file, displayName: displayName, window: window)
        } catch {}
    }

    @MainActor
    static func saveAs(file: URL, displayName: String, window: NSWindow? = nil) async {
        let panel = NSSavePanel()
        panel.title = "Lưu tệp về máy"
        panel.prompt = "Lưu"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sanitizeFilename(displayName)
        if let type = UTType(filenameExtension: (displayName as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = window ?? NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                continuation.resume(returning: panel.runModal())
            }
        }
        if response == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: file, to: dest)
        }
    }

    @MainActor
    static func copyFile(url: URL, displayName: String) async {
        do {
            let file = try await localFile(for: url, displayName: displayName)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([file as NSURL])
        } catch {}
    }
}
