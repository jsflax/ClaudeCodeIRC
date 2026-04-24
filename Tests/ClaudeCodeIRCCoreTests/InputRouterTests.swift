import Foundation
import Testing
import ClaudeCodeIRCCore

@Suite struct InputRouterTests {

    // MARK: - Plain chat

    @Test func plainTextIsMessage() {
        #expect(InputRouter.parse("hello world")
            == .message(text: "hello world", side: false))
    }

    @Test func trimsWhitespace() {
        #expect(InputRouter.parse("   hi   ")
            == .message(text: "hi", side: false))
    }

    @Test func emptyInputIsEmpty() {
        #expect(InputRouter.parse("") == .empty)
        #expect(InputRouter.parse("   \n\t ") == .empty)
    }

    @Test func slashUsrBinIsChat() {
        // Bare "/" prefix without a recognised command should not be
        // swallowed — users legitimately type paths like "/usr/bin".
        // Only the bare "/" (no chars after) falls through to chat;
        // "/foo" (unknown command) becomes .unknown.
        //
        // This test guards the exact "/" case.
        #expect(InputRouter.parse("/")
            == .message(text: "/", side: false))
    }

    // MARK: - /side

    @Test func sideMessage() {
        #expect(InputRouter.parse("/side lmao")
            == .message(text: "lmao", side: true))
    }

    @Test func sideIsCaseInsensitive() {
        #expect(InputRouter.parse("/SIDE lol")
            == .message(text: "lol", side: true))
    }

    @Test func bareSideRejected() {
        // "/side" with no body — don't silently no-op, surface error.
        guard case .unknown = InputRouter.parse("/side") else {
            Issue.record("expected .unknown for bare /side")
            return
        }
    }

    // MARK: - /nick

    @Test func nickHappyPath() {
        #expect(InputRouter.parse("/nick alice") == .setNick("alice"))
    }

    @Test func nickCollapsesMultipleSpacesBeforeArg() {
        // "/nick   bob" → the extra spaces between command and arg
        // are stripped; the arg itself stays intact.
        #expect(InputRouter.parse("/nick   bob") == .setNick("bob"))
    }

    @Test func nickWithWhitespaceRejected() {
        // Whitespace in nicks breaks status-bar rendering ("alice bob"
        // looks like two members). Router rejects.
        guard case .unknown = InputRouter.parse("/nick alice bob") else {
            Issue.record("expected .unknown for /nick with whitespace")
            return
        }
    }

    @Test func bareNickRejected() {
        guard case .unknown = InputRouter.parse("/nick") else {
            Issue.record("expected .unknown for bare /nick")
            return
        }
    }

    // MARK: - /help /members /leave

    @Test func helpCommand() {
        #expect(InputRouter.parse("/help") == .help)
    }

    @Test func membersCommand() {
        #expect(InputRouter.parse("/members") == .members)
    }

    @Test func leaveCommand() {
        #expect(InputRouter.parse("/leave") == .leave)
    }

    // MARK: - unknown

    @Test func unknownCommand() {
        guard case .unknown(let msg) = InputRouter.parse("/foo bar") else {
            Issue.record("expected .unknown for /foo")
            return
        }
        #expect(msg.contains("foo"))
    }
}
