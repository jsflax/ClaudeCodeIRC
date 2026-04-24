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

    // MARK: - Slash-popup completions

    @Test func completionsEmptyPrefixReturnsAllCommands() {
        let all = InputRouter.completions(forPrefix: "")
        #expect(all.count == InputRouter.commands.count)
        #expect(all.map(\.name).contains("nick"))
        #expect(all.map(\.name).contains("leave"))
    }

    @Test func completionsNarrowByPrefix() {
        let hits = InputRouter.completions(forPrefix: "ni")
        #expect(hits.map(\.name) == ["nick"])
    }

    @Test func completionsAreCaseInsensitive() {
        let hits = InputRouter.completions(forPrefix: "HELP")
        #expect(hits.map(\.name) == ["help"])
    }

    @Test func completionsReturnEmptyOnNonMatch() {
        #expect(InputRouter.completions(forPrefix: "zzz").isEmpty)
    }

    // MARK: - /clear /topic /me /afk

    @Test func clearIsParsed() {
        #expect(InputRouter.parse("/clear") == .clear)
        #expect(InputRouter.parse("/CLEAR") == .clear)
        // Trailing noise is trimmed — /clear ignores args.
        #expect(InputRouter.parse("/clear now") == .clear)
    }

    @Test func topicWithBodyIsParsed() {
        #expect(InputRouter.parse("/topic Add WebAuthn + backup codes")
            == .setTopic("Add WebAuthn + backup codes"))
    }

    @Test func bareTopicIsRejected() {
        guard case .unknown(let msg) = InputRouter.parse("/topic") else {
            Issue.record("expected .unknown for bare /topic")
            return
        }
        #expect(msg.contains("topic"))
    }

    @Test func meWithBodyIsAction() {
        #expect(InputRouter.parse("/me opens the NIST doc")
            == .action("opens the NIST doc"))
    }

    @Test func bareMeIsRejected() {
        guard case .unknown = InputRouter.parse("/me") else {
            Issue.record("expected .unknown for bare /me")
            return
        }
    }

    @Test func bareAfkTogglesWithNoReason() {
        #expect(InputRouter.parse("/afk") == .afk(nil))
    }

    @Test func afkWithReasonIncludesText() {
        #expect(InputRouter.parse("/afk brb coffee") == .afk("brb coffee"))
    }

    @Test func afkCaseInsensitive() {
        #expect(InputRouter.parse("/AFK") == .afk(nil))
    }
}
