import ClaudeCodeIRCCore
import NCursesUI

/// Modal text input for the "Other…" row of an `AskQuestionCardView`.
/// Mounted by `WorkspaceView` when the user focuses Other and presses
/// Enter. On submit, the calling code is expected to:
///   1. Append a new `AskOption` to the question's options array
///      (with `submittedByNick = self.nick` and `label = trimmed text`).
///   2. Cast an `AskVote` for the submitter against that label
///      (auto-vote: submitting = endorsing).
/// Both writes happen in `WorkspaceView` so the lattice handle stays
/// in one place and the overlay is purely presentational.
///
/// Esc cancels without writing. Enter on an empty (or
/// whitespace-only) field is treated as cancel — empty labels would
/// be invisible in the option list.
struct AskOtherInputOverlay: View {
    @Binding var isPresented: Bool
    /// Called with the trimmed entered text. The caller decides
    /// whether to append a new option, dedupe to an existing label,
    /// and write the auto-vote.
    let onSubmit: (String) -> Void

    @State private var text: String = ""

    var body: some View {
        BoxView("Other answer", color: .cyan) {
            VStack {
                Text("Type your answer — Enter submits, Esc cancels.")
                    .foregroundColor(.dim)
                SpacerView(1)
                HStack {
                    Text("> ").foregroundColor(.dim)
                    TextField("free-text answer",
                              text: $text,
                              isFocused: .constant(true),
                              onSubmit: submit)
                }
            }
        }
        .onKeyPress(27 /* ESC */) {
            isPresented = false
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isPresented = false
            return
        }
        onSubmit(trimmed)
        isPresented = false
    }
}
