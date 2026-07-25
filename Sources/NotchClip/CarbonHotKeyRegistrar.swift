import Foundation
import AppKit
import Carbon
import NotchClipCore

/// Carbon `RegisterEventHotKey` for the shared NotchClip shortcut with exclusive registration.
/// One logical toggle per physical press/release pair.
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private(set) var isRegistered: Bool = false
    private(set) var registrationError: String?
    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var lastToggleUptime: TimeInterval = 0
    private var isKeyHeld: Bool = false

    private let hotKeyID = EventHotKeyID(signature: OSType(0x4E436C70), id: 1)

    deinit {
        unregister()
    }

    @discardableResult
    func register() -> Bool {
        unregister()

        var eventTypes: [EventTypeSpec] = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            registrar.handleHotKeyEvent(event)
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            2,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            registrationError = "Failed to install hotkey handler (status \(status))."
            isRegistered = false
            return false
        }

        let modifiers = carbonModifiers
        let keyCode = UInt32(kVK_ANSI_V)
        // Exclusive: conflict with another exclusive registration → eventHotKeyExistsErr.
        let options = UInt32(kEventHotKeyExclusive)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            options,
            &hotKeyRef
        )
        guard registerStatus == noErr, hotKeyRef != nil else {
            if let handlerRef {
                RemoveEventHandler(handlerRef)
                self.handlerRef = nil
            }
            if registerStatus == OSStatus(eventHotKeyExistsErr) {
                registrationError = "\(NotchClipHotKey.humanReadableName) is already registered exclusively by another application."
            } else {
                registrationError = "Failed to register \(NotchClipHotKey.humanReadableName) (status \(registerStatus))."
            }
            isRegistered = false
            return false
        }

        isRegistered = true
        registrationError = nil
        return true
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
        isRegistered = false
        isKeyHeld = false
    }

    private func handleHotKeyEvent(_ event: EventRef) {
        let kind = GetEventKind(event)
        if kind == UInt32(kEventHotKeyReleased) {
            isKeyHeld = false
            return
        }
        guard kind == UInt32(kEventHotKeyPressed) else { return }

        if isKeyHeld { return }
        isKeyHeld = true

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastToggleUptime < 0.12 { return }
        lastToggleUptime = now
        DispatchQueue.main.async { [weak self] in
            self?.onToggle?()
        }
    }

    private var carbonModifiers: UInt32 {
        NotchClipHotKey.modifiers.reduce(into: UInt32(0)) { flags, modifier in
            switch modifier {
            case .command:
                flags |= UInt32(cmdKey)
            case .control:
                flags |= UInt32(controlKey)
            case .option:
                flags |= UInt32(optionKey)
            case .shift:
                flags |= UInt32(shiftKey)
            }
        }
    }
}

/// Public Carbon constant (HIToolbox); exposed for tests of exclusive registration option.
enum CarbonHotKeyOptions {
    static let exclusive: UInt32 = UInt32(kEventHotKeyExclusive)
    static let existsError: OSStatus = OSStatus(eventHotKeyExistsErr)
}

// eventHotKeyExistsErr from CarbonEventsCore.h
private let eventHotKeyExistsErr: Int32 = -9878
