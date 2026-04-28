import Foundation
import Lattice

@Model
public final class Session {
    @Unique()
    public var code: String = ""
    public var name: String = ""
    public var cwd: String = ""
    public var permissionMode: PermissionMode = .acceptEdits
    public var createdAt: Date = Date()

    /// Session topic — set via `/topic <text>`, rendered in the top bar.
    /// `nil` means no topic has been set yet.
    public var topic: String? = nil

    /// UUID we pass to every `claude -p --session-id <uuid>` spawn so
    /// claude persists conversation state across prompts — without
    /// this, every `@claude` mention is a blank slate. Assigned by
    /// `LobbyModel.host(...)` at room creation.
    public var claudeSessionId: UUID = UUID()

    public var host: Member?

    /// How this room is announced. `.private` is LAN-only via Bonjour, plus
    /// invite-only over the internet when `publicURL` is non-nil. `.public`
    /// and `.group` opt the room into the directory (L2/L3). Pair with
    /// `groupHashHex` when `visibility == .group`.
    public var visibility: SessionVisibility = .private

    /// `base64url(sha256(groupSecret))` when `visibility == .group`; nil
    /// otherwise. The group secret itself is stored locally in
    /// `prefs.lattice` (`LocalGroup.secretBase64`) — only the hash is
    /// embedded here so the directory bucket is computable, but nothing
    /// in the synced room state lets a non-member compute the secret.
    public var groupHashHex: String? = nil

    /// WS Bearer token required to upgrade against `RoomSyncServer`. Nil
    /// for "open" (auth-less) rooms. Persisted on the Session so the
    /// host can recover the same token across restarts and peers receive
    /// it via sync (they need it for the swap path on tunnel-URL change).
    public var joinCode: String? = nil

    /// Public `wss://...trycloudflare.com/room/<code>` URL when a tunnel
    /// is active. Nil for `.private` rooms with no tunnel up yet, or
    /// before Phase 2 of `host()` resolves. Peers observe changes to
    /// this field and call `RoomInstance.swap()` — that's the wire
    /// signal for tunnel-URL changes (cloudflared restart).
    public var publicURL: String? = nil

    @Relation(link: \Member.session)
    public var members: any Results<Member>

    @Relation(link: \Turn.session)
    public var turns: any Results<Turn>

    @Relation(link: \ChatMessage.session)
    public var messages: any Results<ChatMessage>
}
