import NCursesUI

/// Bottom strip reminding the user of the active keybinds. Rendered
/// dim — visual filler that's always on-screen but never steals
/// attention. D5 lands the interactive bindings these refer to.
struct HotkeyStrip: View {
    var body: some View {
        // Keep segments short so the strip fits in narrow terminals.
        var line = Text("Alt+1..9").foregroundColor(.yellow)
        line = line + Text(" session ").foregroundColor(.dim)
        line = line + Text("^N/^P").foregroundColor(.yellow)
        line = line + Text(" next/prev ").foregroundColor(.dim)
        line = line + Text("Tab").foregroundColor(.yellow)
        line = line + Text(" complete/pane ").foregroundColor(.dim)
        line = line + Text("/").foregroundColor(.yellow)
        line = line + Text(" command ").foregroundColor(.dim)
        line = line + Text("Y/A/D").foregroundColor(.yellow)
        line = line + Text(" approve ").foregroundColor(.dim)
        line = line + Text("⇧Tab").foregroundColor(.yellow)
        line = line + Text(" mode ").foregroundColor(.dim)
        line = line + Text("@claude").foregroundColor(.yellow)
        line = line + Text(" invoke").foregroundColor(.dim)
        return line
    }
}
