import ClaudeCodeIRCCore
import NCursesUI

/// Tab-cycled focus regions in the lobby. Used to route printable-ASCII
/// keys to the right widget: when `.nick`, the TextField claims input;
/// when `.list` or `.host`, printable keys bubble up to root hotkeys.
enum LobbyFocus {
    case list
    case host
    case nick
}

struct LobbyView: View {
    let model: LobbyModel
    let onEnterRoom: (RoomModel) -> Void

    @Environment(\.screen) var screen
    @State private var focus: LobbyFocus = .list
    @State private var selection: String?
    @State private var hostFormVisible: Bool = false
    @State private var joinFormVisible: Bool = false
    @State private var joinCodeInput: String = ""
    @State private var pendingJoin: DiscoveredRoom?
    @State private var lobbyError: String = ""

    private var nickBinding: Binding<String> {
        Binding(
            get: { model.prefs.nick },
            set: { model.prefs.nick = $0 })
    }

    private var listFocusBinding: Binding<Bool> {
        Binding(get: { focus == .list }, set: { _ in })
    }
    private var nickFocusBinding: Binding<Bool> {
        Binding(get: { focus == .nick }, set: { _ in })
    }

    /// The List driven via this binding falls back to the first
    /// discovered room when nothing is explicitly selected. That way
    /// the first row is highlighted as soon as Bonjour finds it — user
    /// doesn't need to press Down to prime the selection.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selection ?? model.browser.rooms.first?.id },
            set: { selection = $0 })
    }

    var body: some View {
        VStack {
            Text("ClaudeCodeIRC").foregroundColor(.cyan).bold()
            SpacerView(1)
            Text("Sessions on this network").foregroundColor(.dim)

            List(model.browser.rooms,
                 selection: selectionBinding,
                 isFocused: listFocusBinding) { room, isSelected in
                // Highlight indicator is visible only when the list
                // region is actually focused — otherwise Tabbing away
                // to host/nick still makes the selected row look
                // active, which is misleading.
                let active = isSelected && focus == .list
                Text("\(active ? "▸ " : "  ")\(room.name)  \(room.cwd)")
                    .foregroundColor(active ? .cyan : .white)
            }
            .onSubmit(isFocused: listFocusBinding) {
                // Use the binding's effective value so a default-highlighted
                // first row activates on Enter even without explicit arrows.
                guard let id = selectionBinding.wrappedValue,
                      let room = model.browser.rooms.first(where: { $0.id == id })
                else { return }
                if room.requiresJoinCode {
                    pendingJoin = room
                    joinCodeInput = ""
                    joinFormVisible = true
                } else {
                    // Open room — no prompt, connect straight through.
                    do {
                        let r = try model.join(room, joinCode: nil)
                        onEnterRoom(r)
                    } catch {
                        lobbyError = "join failed: \(error)"
                    }
                }
            }

            SpacerView(1)
            Text("─ or ─").foregroundColor(.dim)
            Text("[ Host a new session ]")
                .foregroundColor(focus == .host ? .cyan : .white)
                .reverse(focus == .host)
            SpacerView(1)

            HStack {
                Text("nick: ").foregroundColor(.dim)
                TextField("enter your nick",
                          text: nickBinding,
                          isFocused: nickFocusBinding)
            }

            SpacerView(1)
            Text("↵ join/host   ⇥ switch   q quit").foregroundColor(.dim)
            if !lobbyError.isEmpty {
                Text(lobbyError).foregroundColor(.red)
            }
        }
        .onKeyPress(9 /* Tab */) {
            focus = switch focus {
            case .list: .host
            case .host: .nick
            case .nick: .list
            }
        }
        .onKeyPress(Int32(UInt8(ascii: "\n"))) {
            // List and TextField claim Enter themselves when focused;
            // this handler only fires when focus == .host.
            if focus == .host {
                hostFormVisible = true
            }
        }
        .onKeyPress(Int32(UInt8(ascii: "q"))) {
            // Only acts as quit when a text field isn't focused (it'd
            // claim the 'q' first otherwise).
            if focus != .nick {
                screen?.shouldExit = true
            }
        }
        .overlay(isPresented: $hostFormVisible, dimsBackground: true) {
            HostFormOverlay(
                model: model,
                isPresented: $hostFormVisible,
                onCreated: { room in
                    hostFormVisible = false
                    onEnterRoom(room)
                })
        }
        .overlay(isPresented: $joinFormVisible, dimsBackground: true) {
            JoinFormOverlay(
                model: model,
                room: pendingJoin,
                joinCode: $joinCodeInput,
                isPresented: $joinFormVisible,
                onJoined: { room in
                    joinFormVisible = false
                    onEnterRoom(room)
                })
        }
    }
}

/// Host form — two TextFields (name, cwd) + a "require join code"
/// toggle, cycled via Tab. Default is require-code (safer for a
/// LAN-advertised room). Space on the toggle flips it. Ctrl+C submits;
/// ESC dismisses.
enum HostFormFocus { case name, cwd, auth }

struct HostFormOverlay: View {
    let model: LobbyModel
    @Binding var isPresented: Bool
    let onCreated: (RoomModel) -> Void

    @State private var focus: HostFormFocus = .name
    @State private var name: String = ""
    @State private var requireCode: Bool = true
    @State private var error: String = ""

    private var cwdBinding: Binding<String> {
        Binding(
            get: { model.prefs.lastCwd },
            set: { model.prefs.lastCwd = $0 })
    }
    private var nameFocus: Binding<Bool> {
        Binding(get: { focus == .name }, set: { _ in })
    }
    private var cwdFocus: Binding<Bool> {
        Binding(get: { focus == .cwd }, set: { _ in })
    }

    var body: some View {
        BoxView("Host a new session", color: .cyan) {
            VStack {
                HStack {
                    Text("name: ").foregroundColor(.dim)
                    TextField("my session",
                              text: $name,
                              isFocused: nameFocus,
                              onSubmit: submit)
                }
                HStack {
                    Text("cwd:  ").foregroundColor(.dim)
                    TextField("/path/to/repo",
                              text: cwdBinding,
                              isFocused: cwdFocus,
                              onSubmit: submit)
                }
                HStack {
                    Text("\(requireCode ? "[x]" : "[ ]") require join code")
                        .foregroundColor(focus == .auth ? .cyan : .white)
                        .reverse(focus == .auth)
                }
                SpacerView(1)
                Text("⇥ switch   space toggle   ↵ create   ⎋ cancel")
                    .foregroundColor(.dim)
                if !error.isEmpty {
                    Text(error).foregroundColor(.red)
                }
            }
        }
        .onKeyPress(9 /* Tab */) {
            focus = switch focus {
            case .name: .cwd
            case .cwd:  .auth
            case .auth: .name
            }
        }
        .onKeyPress(Int32(UInt8(ascii: " "))) {
            // Space only toggles when the auth checkbox is focused —
            // otherwise space is a legit character for TextFields.
            if focus == .auth {
                requireCode.toggle()
            }
        }
        .onKeyPress(Int32(UInt8(ascii: "\n"))) {
            // TextField claims Enter when focused and fires onSubmit →
            // submit(). This root handler only runs when focus == .auth
            // (neither TextField holds the key). Same submit path.
            if focus == .auth {
                submit()
            }
        }
        .onKeyPress(27 /* ESC */) {
            isPresented = false
        }
    }

    private func submit() {
        Task {
            do {
                let room = try await model.host(
                    name: name.isEmpty ? "unnamed" : name,
                    cwd: model.prefs.lastCwd,
                    mode: .default,
                    requireJoinCode: requireCode)
                onCreated(room)
            } catch {
                self.error = "\(error)"
            }
        }
    }
}

/// Join form — one TextField for the join code. Enter submits, ESC cancels.
struct JoinFormOverlay: View {
    let model: LobbyModel
    let room: DiscoveredRoom?
    @Binding var joinCode: String
    @Binding var isPresented: Bool
    let onJoined: (RoomModel) -> Void

    @State private var error: String = ""

    var body: some View {
        BoxView("Join", color: .cyan) {
            VStack {
                if let room {
                    Text("room: \(room.name)").foregroundColor(.dim)
                    Text("host: \(room.hostNick)").foregroundColor(.dim)
                    SpacerView(1)
                    HStack {
                        Text("code: ").foregroundColor(.dim)
                        TextField("6-char join code",
                                  text: $joinCode,
                                  isFocused: .constant(true),
                                  onSubmit: { submit() })
                    }
                } else {
                    Text("no room selected").foregroundColor(.red)
                }
                SpacerView(1)
                Text("↵ join   ⎋ cancel").foregroundColor(.dim)
                if !error.isEmpty {
                    Text(error).foregroundColor(.red)
                }
            }
        }
        .onKeyPress(27 /* ESC */) {
            isPresented = false
        }
    }

    private func submit() {
        guard let room else { return }
        do {
            let r = try model.join(room, joinCode: joinCode)
            onJoined(r)
        } catch {
            self.error = "\(error)"
        }
    }
}
