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

    /// UUID we pass to every `claude -p --session-id <uuid>` spawn so
    /// claude persists conversation state across prompts — without
    /// this, every `@claude` mention is a blank slate. Assigned by
    /// `LobbyModel.host(...)` at room creation.
    public var claudeSessionId: UUID = UUID()

    public var host: Member?

    @Relation(link: \Member.session)
    public var members: any Results<Member>

    @Relation(link: \Turn.session)
    public var turns: any Results<Turn>

    @Relation(link: \ChatMessage.session)
    public var messages: any Results<ChatMessage>
}
