import ClaudeCodeIRCCore
import NCursesUI

/// Modal list of palette choices. Enter on a row writes the pick to
/// `AppPreferences.paletteId` and closes the overlay; the app
/// observes that change and calls `PaletteRegistrar.activate(_:)` so
/// the whole UI repaints with the new theme.
///
/// Opened by `/palette` or (future) a function key. ESC dismisses
/// without changing the pref.
struct PaletteSelectorOverlay: View {
    let prefs: AppPreferences
    @Binding var isPresented: Bool

    @State private var selection: String

    init(prefs: AppPreferences, isPresented: Binding<Bool>) {
        self.prefs = prefs
        self._isPresented = isPresented
        self._selection = State(wrappedValue: prefs.paletteId.rawValue)
    }

    var body: some View {
        BoxView("Palette", color: .cyan) {
            VStack {
                Text("Pick a palette — arrows to move, Enter to apply, ESC to cancel.")
                    .foregroundColor(.dim)
                SpacerView(1)
                List(PaletteId.allCases.map(IdRow.init),
                     selection: Binding(
                        get: { selection },
                        set: { selection = $0 ?? selection }),
                     isFocused: .constant(true)) { row, isSelected in
                    Text(label(for: row.palette))
                        .foregroundColor(isSelected ? .cyan : .white)
                        .reverse(isSelected)
                }
                .onSubmit(isFocused: .constant(true)) {
                    guard let picked = PaletteId(rawValue: selection) else { return }
                    prefs.paletteId = picked
                    isPresented = false
                }
            }
        }
        .onKeyPress(27 /* ESC */) {
            isPresented = false
        }
    }

    private func label(for id: PaletteId) -> String {
        switch id {
        case .phosphor: return "phosphor — CRT green"
        case .amber:    return "amber — vintage orange"
        case .modern:   return "modern — soft dark"
        case .claude:   return "claude — warm rust"
        }
    }
}

/// List requires its elements to be Identifiable. PaletteId itself
/// isn't (it's a @LatticeEnum / raw-string enum); wrap each case
/// into a thin struct whose `id` is the raw name.
private struct IdRow: Identifiable {
    let id: String
    let palette: PaletteId
    init(_ palette: PaletteId) {
        self.id = palette.rawValue
        self.palette = palette
    }
}
