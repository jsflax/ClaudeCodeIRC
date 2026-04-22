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

    public var host: Member?

    @Relation(link: \Member.session)
    public var members: any Results<Member>

    @Relation(link: \Turn.session)
    public var turns: any Results<Turn>

    @Relation(link: \ChatMessage.session)
    public var messages: any Results<ChatMessage>
}
