import ClaudeCodeIRCCore
import NCursesUI

struct LobbyView: View {
    let model: LobbyModel
    let onEnterRoom: (RoomModel) -> Void

    @Environment(\.screen) var screen
    @State private var selection: String?
    @State private var hostFormVisible: Bool = false
    @State private var joinFormVisible: Bool = false
    @State private var joinCodeInput: String = ""
    @State private var pendingJoin: DiscoveredRoom?

    private var nickBinding: Binding<String> {
        Binding(
            get: { model.prefs.nick },
            set: { model.prefs.nick = $0 })
    }

    var body: some View {
        VStack {
            Text("ClaudeCodeIRC").foregroundColor(.cyan).bold()
            SpacerView(1)
            Text("Sessions on this network").foregroundColor(.dim)

            List(model.browser.rooms, selection: $selection) { room, isSelected in
                Text("\(isSelected ? "▸ " : "  ")\(room.name)  \(room.cwd)")
                    .foregroundColor(isSelected ? .cyan : .white)
            }
            .onSubmit {
                guard let id = selection,
                      let room = model.browser.rooms.first(where: { $0.id == id })
                else { return }
                pendingJoin = room
                joinCodeInput = ""
                joinFormVisible = true
            }

            SpacerView(1)
            Text("─ or ─").foregroundColor(.dim)
            Text("[H] host a new session").foregroundColor(.cyan)
            SpacerView(1)

            HStack {
                Text("nick: ").foregroundColor(.dim)
                TextField("enter your nick", text: nickBinding)
            }

            SpacerView(1)
            Text("q quit").foregroundColor(.dim)
        }
        .onKeyPress(Int32(UInt8(ascii: "q"))) {
            screen?.shouldExit = true
        }
        .onKeyPress(Int32(UInt8(ascii: "h"))) {
            hostFormVisible = true
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

struct HostFormOverlay: View {
    let model: LobbyModel
    @Binding var isPresented: Bool
    let onCreated: (RoomModel) -> Void

    @State private var name: String = ""
    @State private var error: String = ""

    private var cwdBinding: Binding<String> {
        Binding(
            get: { model.prefs.lastCwd },
            set: { model.prefs.lastCwd = $0 })
    }

    var body: some View {
        VStack {
            Text("─ Host a new session ─").bold()
            SpacerView(1)
            HStack {
                Text("name: ").foregroundColor(.dim)
                TextField("my session", text: $name)
            }
            HStack {
                Text("cwd:  ").foregroundColor(.dim)
                TextField("/path/to/repo", text: cwdBinding)
            }
            SpacerView(1)
            Text("[↵] create   [ESC] cancel").foregroundColor(.dim)
            if !error.isEmpty {
                Text(error).foregroundColor(.red)
            }
        }
        .onKeyPress(27 /* ESC */) {
            isPresented = false
        }
        .onKeyPress(Int32(UInt8(ascii: "\n"))) {
            Task {
                do {
                    let room = try await model.host(
                        name: name.isEmpty ? "unnamed" : name,
                        cwd: model.prefs.lastCwd,
                        mode: .acceptEdits)
                    onCreated(room)
                } catch {
                    self.error = "\(error)"
                }
            }
        }
    }
}

struct JoinFormOverlay: View {
    let model: LobbyModel
    let room: DiscoveredRoom?
    @Binding var joinCode: String
    @Binding var isPresented: Bool
    let onJoined: (RoomModel) -> Void

    @State private var error: String = ""

    var body: some View {
        VStack {
            Text("─ Join ─").bold()
            SpacerView(1)
            if let room {
                Text("room: \(room.name)").foregroundColor(.dim)
                Text("host: \(room.hostNick)").foregroundColor(.dim)
                SpacerView(1)
                HStack {
                    Text("code: ").foregroundColor(.dim)
                    TextField("6-char join code", text: $joinCode)
                }
            } else {
                Text("no room selected").foregroundColor(.red)
            }
            SpacerView(1)
            Text("[↵] join   [ESC] cancel").foregroundColor(.dim)
            if !error.isEmpty {
                Text(error).foregroundColor(.red)
            }
        }
        .onKeyPress(27 /* ESC */) {
            isPresented = false
        }
        .onKeyPress(Int32(UInt8(ascii: "\n"))) {
            guard let room else { return }
            do {
                let r = try model.join(room, joinCode: joinCode)
                onJoined(r)
            } catch {
                self.error = "\(error)"
            }
        }
    }
}
