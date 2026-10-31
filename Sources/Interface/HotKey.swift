import Carbon
import Search

/// Why the hotkey won't show the panel.
public enum HotKeyConflict: Error, Equatable, Sendable {
    /// A macOS keyboard shortcut that is turned on uses the chord, as Spotlight's uses ⌘Space.
    /// macOS takes those keys before any app, though registering the chord succeeds.
    case systemShortcut
    /// `RegisterEventHotKey` refused the chord with this status: `eventHotKeyExistsErr` when
    /// another app has registered it.
    case refused(OSStatus)
}

/// A keyboard shortcut macOS handles itself, as System Settings → Keyboard → Keyboard Shortcuts
/// lists them.
public struct SystemHotKey: Equatable, Sendable {
    /// Carbon's modifier masks, as `KeyChord.Modifiers` holds them, plus any others macOS sets,
    /// such as the Fn key's.
    public let modifiers: UInt32
    public let code: UInt16
    public let isEnabled: Bool

    public init(modifiers: UInt32, code: UInt16, isEnabled: Bool) {
        self.modifiers = modifiers
        self.code = code
        self.isEnabled = isEnabled
    }
}

/// Makes a chord call back from anywhere. A protocol so tests can record registrations rather
/// than take a chord from the whole system.
@MainActor
public protocol HotKeyRegistrar: AnyObject {
    /// Makes `chord` call `onPress`, in place of a chord registered before. On failure the chord
    /// registered before stays.
    func register(_ chord: KeyChord, onPress: @escaping @MainActor () -> Void)
        throws(HotKeyConflict)
    /// Gives the registered chord back to the system, if there is one.
    func unregister()
}

/// A global hotkey through Carbon's `RegisterEventHotKey`, the one API that takes a chord from
/// every app without the Accessibility permission (docs/decisions/0009-app-wiring.md).
@MainActor
public final class HotKey: HotKeyRegistrar {
    /// The signature of this app's hotkey IDs: "SSpt".
    private static let signature: OSType = 0x5353_7074

    // Read by `deinit`, which isn't on the main actor.
    nonisolated(unsafe) private var registered: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?
    /// The ID of the latest registration, so a press of a chord replaced since is ignored.
    private var id: UInt32 = 0
    private var onPress: (@MainActor () -> Void)?
    /// The chord `registered` holds.
    private var current: KeyChord?

    public init() {}

    deinit {
        if let registered { UnregisterEventHotKey(registered) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Registers the new chord before giving up the old one, so a chord that is refused leaves
    /// the one that works.
    public func register(_ chord: KeyChord, onPress: @escaping @MainActor () -> Void)
        throws(HotKeyConflict)
    {
        if chord == current, registered != nil {
            self.onPress = onPress
            return
        }
        try installHandler()
        let newID = id + 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(chord.key.code), chord.modifiers.rawValue,
            EventHotKeyID(signature: Self.signature, id: newID), GetApplicationEventTarget(), 0,
            &reference)
        guard status == noErr, let reference else { throw .refused(status) }
        unregister()
        id = newID
        registered = reference
        current = chord
        self.onPress = onPress
    }

    public func unregister() {
        onPress = nil
        current = nil
        guard let registered else { return }
        UnregisterEventHotKey(registered)
        self.registered = nil
    }

    /// Whether a macOS shortcut in `shortcuts` that is turned on uses `chord`. Modifiers other
    /// than the four a chord can hold, as the Fn mask macOS adds to F-key shortcuts, don't count.
    public nonisolated static func systemShortcutUses(
        _ chord: KeyChord, in shortcuts: [SystemHotKey]
    ) -> Bool {
        let mask = KeyChord.Modifiers([.command, .shift, .option, .control]).rawValue
        return shortcuts.contains {
            $0.isEnabled && $0.code == chord.key.code
                && $0.modifiers & mask == chord.modifiers.rawValue
        }
    }

    /// The keyboard shortcuts macOS handles itself, turned on or off, from `CopySymbolicHotKeys`.
    public nonisolated static func systemHotKeys() throws -> [SystemHotKey] {
        var array: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&array)
        guard status == noErr, let array else {
            throw SystemHotKeyError(status: status)
        }
        guard let entries = array.takeRetainedValue() as? [[String: Any]] else {
            throw SystemHotKeyError(status: status)
        }
        return entries.compactMap { entry in
            guard let code = (entry[kHISymbolicHotKeyCode] as? NSNumber)?.uint16Value,
                let modifiers = (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value,
                let enabled = entry[kHISymbolicHotKeyEnabled] as? Bool
            else { return nil }
            return SystemHotKey(modifiers: modifiers, code: code, isEnabled: enabled)
        }
    }

    /// Installs the handler of hotkey presses on the application's event target, once.
    private func installHandler() throws(HotKeyConflict) {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var pressedID = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
                guard read == noErr else { return read }
                // Carbon delivers hotkey events through the main run loop.
                return MainActor.assumeIsolated {
                    Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().pressed(pressedID)
                }
            }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw .refused(status) }
    }

    private func pressed(_ pressedID: EventHotKeyID) -> OSStatus {
        guard pressedID.signature == Self.signature, pressedID.id == id, let onPress else {
            return OSStatus(eventNotHandledErr)
        }
        onPress()
        return noErr
    }
}

/// macOS's list of its own keyboard shortcuts couldn't be read.
public struct SystemHotKeyError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        "couldn't read macOS's keyboard shortcuts (status \(status))"
    }
}
