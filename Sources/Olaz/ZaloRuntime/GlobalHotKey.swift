import AppKit
import Carbon

/// Global hotkey listener using Carbon's `RegisterEventHotKey` (HIToolbox).
///
/// Unlike `CGEventTap` or `NSEvent` monitors, Carbon hotkeys:
/// - Work system-wide even when the application is in the background or not focused.
/// - Do NOT require Accessibility permissions in System Settings.
/// - Are the exact mechanism used by Electron (and official Zalo PC) for global shortcuts.
final class GlobalHotKey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType
    private let id: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: @MainActor () -> Void

    init(keyCode: UInt32 = UInt32(kVK_ANSI_S),
         modifiers: UInt32 = UInt32(cmdKey | optionKey),
         signature: OSType = 0x4F4C415A, // "OLAZ"
         id: UInt32 = 1,
         action: @escaping @MainActor () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.signature = signature
        self.id = id
        self.action = action
    }

    deinit {
        unregister()
    }

    @discardableResult
    func register() -> Bool {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (handlerCallRef, eventRef, userData) -> OSStatus in
                guard let userData, let event = eventRef else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                    if hotKeyID.signature == instance.signature && hotKeyID.id == instance.id {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                instance.action()
                            }
                        }
                        return noErr
                    }
                }
                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            pointer,
            &handlerRef
        )

        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        return registerStatus == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
