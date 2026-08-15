/// Host-free routing decision for text an accessibility client hands to the terminal through
/// `AXValue` (`GhosttySurfaceView.setAccessibilityValue`, the dictation bridge).
///
/// The app-side setter has two destinations — the keyboard/IME `insertText` path for inline text, and
/// the bracketed-paste `insertPasted` path for anything carrying a CONTROL character, so an embedded
/// newline lands as literal text instead of typing Return and submitting the line, and an embedded tab
/// lands as a tab instead of firing the shell's completion. Only the *decision* lives here; the two
/// insert calls are AppKit/libghostty and stay in the app target.
public enum AccessibilityInsert {
    /// True when `text` carries anything a terminal would read as a control keypress rather than as
    /// literal characters, and must therefore take the bracketed-paste path.
    ///
    /// Two terms, because neither covers the other:
    ///
    /// - `Character.isNewline` for the line breaks ABOVE C0 — NEL (U+0085), LS (U+2028) and PS (U+2029) —
    ///   which the scalar term below does not reach. It is deliberately not
    ///   `text.contains("\n") || text.contains("\r")`: `String` is a collection of grapheme clusters and
    ///   CRLF is a SINGLE cluster equal to neither, so the naive pair reports false for `"ls -la\r\n"`,
    ///   which is what a browser `<textarea>` value carries per the HTML spec and so what a dictation
    ///   client is likely to hand over. CRLF itself is caught either way, since `unicodeScalars` sees its
    ///   U+000D and U+000A separately.
    /// - the C0 range (U+0000–U+001F) plus DEL (U+007F) for every other control character. A TAB is the
    ///   live case: unwrapped, `insertText` hands 0x09 to the shell, readline reads it as completion and
    ///   expands a filename or spews a candidate list instead of inserting the text — and a tab is
    ///   ordinary in an indented snippet or in text pulled from a `<textarea>`. ESC and the rest of the
    ///   range are the same class of hazard, so the whole range routes to paste.
    ///
    /// What the paste route buys is the program's bracketed-paste mode (2004), NOT an unconditional
    /// guarantee — the same caveat that already qualifies the line-break case, and it qualifies the control
    /// characters identically. Against a program with 2004 OFF (a raw `sh` prompt, `cat`, a bash built
    /// without `enable-bracketed-paste`) the payload still reaches the pty as raw bytes, so a dictated tab
    /// fires completion and a dictated ESC is read as ESC. Routing is an improvement in the common case,
    /// not a promise in every case.
    ///
    /// Ordinary prose — the overwhelmingly common dictation payload — contains none of these and keeps
    /// the keyboard/IME path, which is what preserves IME behaviour for inline text.
    public static func needsPasteRouting(_ text: String) -> Bool {
        if text.contains(where: \.isNewline) { return true }
        return text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
