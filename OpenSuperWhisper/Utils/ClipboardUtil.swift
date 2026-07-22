import Cocoa
import ApplicationServices
import Carbon

class ClipboardUtil {

    typealias PasteboardContents = ([NSPasteboard.PasteboardType: Any], [NSPasteboard.PasteboardType])

    /// Slow consumers (browsers, Electron apps) can service the synthesized
    /// Cmd+V long after the event is posted. Restoring the original clipboard
    /// before the target reads it makes them paste the old contents instead of
    /// the transcription. AppKit paste is a *read* of the pasteboard, so there
    /// is no public signal that the paste was consumed (reads never advance
    /// `changeCount`). We therefore wait a generous window before restoring and
    /// abort the restore the instant anyone else writes to the pasteboard, so
    /// we never clobber newer clipboard contents.
    static let clipboardRestoreDelay: TimeInterval = 1.5

    /// Interval between `changeCount` polls while waiting to restore.
    static let clipboardRestorePollInterval: TimeInterval = 0.05

    /// Human-readable no-speech sentinel surfaced by the transcription pipeline
    /// (see `ContentView` / `IndicatorWindow`). The engines themselves return an
    /// empty string for silence; both cases are treated as "nothing to inject".
    static let noSpeechSentinel = "No speech detected"

    /// Serial queue used to wait for, and restore, the clipboard off the main
    /// thread so a slow paste consumer never blocks the UI.
    private static let restoreQueue = DispatchQueue(label: "com.opensuperwhisper.clipboard-restore",
                                                    qos: .utility)

    /// True when `text` carries no dictation and must not be injected: an empty
    /// or whitespace-only result, or the no-speech sentinel phrase.
    static func isNoSpeechResult(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == noSpeechSentinel
    }

    /// Copies text to clipboard without pasting or restoring
    static func copyToClipboard(_ text: String) {
        // Fail-closed: never write a no-speech result to the clipboard.
        guard !isNoSpeechResult(text) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    /// Pastes text and keeps it in clipboard (does not restore original clipboard)
    static func insertTextAndKeepInClipboard(_ text: String) {
        // Fail-closed: no clipboard write and no synthesized keystroke for a
        // no-speech result.
        guard !isNoSpeechResult(text) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        simulatePaste()
    }

    /// Pastes text and restores original clipboard (legacy behavior)
    static func insertText(_ text: String) {
        // Fail-closed: no clipboard write and no synthesized keystroke for a
        // no-speech result.
        guard !isNoSpeechResult(text) else { return }

        let pasteboard = NSPasteboard.general

        // Save current pasteboard contents
        let savedContents = saveCurrentPasteboardContents(from: pasteboard)

        // Set new text to pasteboard
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        let changeCountAfterCopy = pasteboard.changeCount

        // Simulate Cmd+V using layout-aware keycode resolution
        simulatePaste()

        // Restore original contents only after the target app had a chance to
        // process the paste. We can't observe the paste itself (it's a read),
        // so we poll off the main thread until either someone else writes to the
        // pasteboard — in which case we abort, leaving their newer data intact —
        // or the generous window elapses and the clipboard still holds our text.
        guard let contents = savedContents else { return }
        scheduleRestore(contents, expectedChangeCount: changeCountAfterCopy, pasteboard: pasteboard)
    }

    /// Waits — off the main thread — for a slow paste consumer, then restores the
    /// original clipboard. Polls `changeCount`: any advance means another writer
    /// took the pasteboard, so we abort rather than clobber it. If the window
    /// elapses with our text still in place, we restore the saved contents.
    private static func scheduleRestore(_ contents: PasteboardContents,
                                        expectedChangeCount: Int,
                                        pasteboard: NSPasteboard) {
        restoreQueue.async {
            let deadline = Date().addingTimeInterval(clipboardRestoreDelay)
            while Date() < deadline {
                // Someone else wrote to the clipboard — leave their content alone.
                if pasteboard.changeCount != expectedChangeCount { return }
                Thread.sleep(forTimeInterval: clipboardRestorePollInterval)
            }
            restoreIfUnchanged(contents, expectedChangeCount: expectedChangeCount, pasteboard: pasteboard)
        }
    }

    @discardableResult
    static func restoreIfUnchanged(_ contents: PasteboardContents,
                                   expectedChangeCount: Int,
                                   pasteboard: NSPasteboard = .general) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        restorePasteboardContents(contents, to: pasteboard)
        return true
    }
    
    private static func simulatePaste() {
        sendCmdV()
    }
    
    private static func sendCmdV() {
        // QWERTY keycode for V
        let qwertyKeyCodeV: CGKeyCode = 9
        
        // Determine the correct keycode for Cmd+V
        let keyCodeV: CGKeyCode
        
        if isQwertyCommandLayout() {
            // For layouts like "Dvorak - QWERTY ⌘" that use QWERTY for Command shortcuts
            keyCodeV = qwertyKeyCodeV
        } else if let foundKeycode = findKeycodeForCharacter("v") {
            // For layouts where shortcuts follow the layout (Dvorak Left/Right Hand)
            keyCodeV = foundKeycode
        } else {
            // Fallback for non-Latin layouts (Russian, etc.) - use QWERTY keycode
            keyCodeV = qwertyKeyCodeV
        }
        
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else { return }
        
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
    
    static func isQwertyCommandLayout() -> Bool {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return false }
        
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        
        // "Dvorak - QWERTY ⌘" uses QWERTY positions for Command shortcuts
        // Its ID contains "DVORAK-QWERTY" or similar patterns
        // Also standard QWERTY, ABC, US layouts use keycode 9 for V
        let qwertyCommandLayouts = [
            "DVORAK-QWERTY",  // Dvorak - QWERTY ⌘
            "US",             // US QWERTY
            "ABC",            // ABC
            "Australian",     // Australian
            "British",        // British
            "Canadian",       // Canadian
            "USInternational" // US International
        ]
        
        let upperID = sourceID.uppercased()
        return qwertyCommandLayouts.contains { upperID.contains($0.uppercased()) }
    }
    
    static func findKeycodeForCharacter(_ char: Character) -> CGKeyCode? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        
        let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )
        
        let targetLower = char.lowercased()
        
        // Iterate through common keycodes (0-50 covers all letter keys)
        for keycode: UInt16 in 0...50 {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            
            let status = UCKeyTranslate(
                keyboardLayout,
                keycode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
            
            if status == noErr && length > 0 {
                let resultChar = Character(UnicodeScalar(chars[0])!)
                if resultChar.lowercased() == targetLower {
                    return CGKeyCode(keycode)
                }
            }
        }
        return nil
    }
    
    static func saveCurrentPasteboardContents(from pasteboard: NSPasteboard = .general) -> PasteboardContents? {
        let types = pasteboard.types ?? []
        
        guard !types.isEmpty else { return nil }
        
        var savedContents: [NSPasteboard.PasteboardType: Any] = [:]
        
        for type in types {
            if let data = pasteboard.data(forType: type) {
                savedContents[type] = data
            } else if let string = pasteboard.string(forType: type) {
                savedContents[type] = string
            } else if let urls = pasteboard.propertyList(forType: type) as? [String] {
                savedContents[type] = urls
            }
        }
        
        return (!savedContents.isEmpty) ? (savedContents, types) : nil
    }
    
    static func restorePasteboardContents(_ contents: PasteboardContents, to pasteboard: NSPasteboard = .general) {
        let (savedContents, types) = contents
        
        pasteboard.declareTypes(types, owner: nil)
        
        for (type, content) in savedContents {
            if let data = content as? Data {
                pasteboard.setData(data, forType: type)
            } else if let string = content as? String {
                pasteboard.setString(string, forType: type)
            } else if let urls = content as? [String] {
                pasteboard.setPropertyList(urls, forType: type)
            }
        }
    }
    
    @available(*, deprecated, renamed: "insertText")
    static func insertTextUsingPasteboard(_ text: String) {
        insertText(text)
    }
    
    // MARK: - Testing Helpers
    
    static func getCurrentInputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }
    
    static func switchToInputSource(withID targetID: String) -> Bool {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            
            if sourceID.contains(targetID) || targetID.contains(sourceID) || sourceID == targetID {
                let result = TISSelectInputSource(source)
                usleep(100000) // 100ms delay for layout switch
                return result == noErr
            }
        }
        return false
    }
    
    static func getAvailableInputSources() -> [String] {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        
        var result: [String] = []
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let selectablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            else { continue }
            
            let isSelectable = unsafeBitCast(selectablePtr, to: CFBoolean.self) == kCFBooleanTrue
            if isSelectable {
                let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                result.append(sourceID)
            }
        }
        return result
    }
}
