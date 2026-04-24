import Testing
import ClaudeCodeIRCCore

@Suite struct ClaudeMentionTests {
    @Test func matchesLeadingMention() {
        #expect(ClaudeMention.matches("@claude can you look at this"))
    }

    @Test func matchesMidSentence() {
        #expect(ClaudeMention.matches("hey @claude what do you think"))
    }

    @Test func matchesCaseInsensitive() {
        #expect(ClaudeMention.matches("@Claude hi"))
        #expect(ClaudeMention.matches("@CLAUDE"))
        #expect(ClaudeMention.matches("hi @cLaUdE"))
    }

    @Test func matchesTrailingPunctuation() {
        #expect(ClaudeMention.matches("@claude, look at this"))
        #expect(ClaudeMention.matches("@claude."))
        #expect(ClaudeMention.matches("ok @claude?"))
        #expect(ClaudeMention.matches("wait @claude!"))
    }

    @Test func rejectsEmailLike() {
        #expect(!ClaudeMention.matches("email me at foo@claude.com"))
    }

    @Test func rejectsLongerWord() {
        #expect(!ClaudeMention.matches("@claudette is a different name"))
    }

    @Test func rejectsNoMention() {
        #expect(!ClaudeMention.matches("just a regular message"))
        #expect(!ClaudeMention.matches(""))
        #expect(!ClaudeMention.matches("claude without the at"))
    }

    @Test func rejectsEmbeddedWithoutBoundary() {
        #expect(!ClaudeMention.matches("say@claudeis weird"))
    }
}
