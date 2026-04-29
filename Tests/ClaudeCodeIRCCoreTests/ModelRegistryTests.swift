import Foundation
import Testing
@testable import ClaudeCodeIRCCore

@Suite struct ModelRegistryTests {

    @Test func knownIdReturnsTableEntry() {
        let info = ModelRegistry.info(for: "claude-opus-4-7")
        #expect(info.displayName == "Opus 4.7")
        #expect(info.contextWindow == 200_000)
    }

    @Test func oneMillionContextOpusVariant() {
        let info = ModelRegistry.info(for: "claude-opus-4-7[1m]")
        #expect(info.displayName == "Opus 4.7 (1M context)")
        #expect(info.contextWindow == 1_000_000)
    }

    @Test func unknownIdFallsBackToRawIdAndDefaultWindow() {
        let info = ModelRegistry.info(for: "claude-future-9-9")
        // Unknown ids forward the raw id as the display name so users
        // see what the transcript reported (rather than a generic
        // "Claude") and we assume a 200k window — the default for
        // every shipped Anthropic model as of 2026-04.
        #expect(info.displayName == "claude-future-9-9")
        #expect(info.contextWindow == 200_000)
    }

    @Test func haiku45BothIdShapes() {
        // Haiku ships with both a dated (`claude-haiku-4-5-20251001`)
        // and stable (`claude-haiku-4-5`) id. Make sure both resolve.
        #expect(ModelRegistry.info(for: "claude-haiku-4-5").displayName == "Haiku 4.5")
        #expect(ModelRegistry.info(for: "claude-haiku-4-5-20251001").displayName == "Haiku 4.5")
    }
}

/// Opt-in freshness check against the Anthropic Models API. Skips
/// silently unless `ANTHROPIC_API_KEY` is set in the environment so
/// CI without the key (and most local runs) don't see false failures.
///
/// Asserts that every `claude-*` model id the API currently returns
/// is present in `ModelRegistry.known`. Catches the "Anthropic shipped
/// a new variant we haven't added" drift case at the next CI run with
/// the key set; we then bump the table.
@Suite struct ModelRegistryFreshnessTests {

    /// `try #require` fails the test on a false condition; for a true
    /// "skip if env var missing" we just early-return silently. swift-
    /// testing has no first-class skip API yet, so this is the idiom.
    @Test func registryCoversApiModels() async throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            return
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = try #require(resp as? HTTPURLResponse)
        try #require(http.statusCode == 200)

        struct ListResponse: Decodable {
            struct Model: Decodable { let id: String; let displayName: String?
                enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" }
            }
            let data: [Model]
        }
        let listing = try JSONDecoder().decode(ListResponse.self, from: data)
        let claudeModels = listing.data.filter { $0.id.hasPrefix("claude-") }

        var missing: [String] = []
        for m in claudeModels where ModelRegistry.known[m.id] == nil {
            missing.append(m.id)
        }
        #expect(missing.isEmpty, "ModelRegistry missing entries for: \(missing.joined(separator: ", "))")
    }
}
