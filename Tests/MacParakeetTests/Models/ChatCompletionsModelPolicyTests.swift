import XCTest
@testable import MacParakeetCore

final class ChatCompletionsModelPolicyTests: XCTestCase {
    func testCanonicalIDStripsOpenRouterPrefix() {
        XCTAssertEqual(
            ChatCompletionsModelPolicy.canonicalModelID("moonshotai/kimi-k2.6"),
            "kimi-k2.6"
        )
        XCTAssertEqual(
            ChatCompletionsModelPolicy.canonicalModelID("deepseek/deepseek-v4-flash"),
            "deepseek-v4-flash"
        )
    }

    func testKimiFamiliesFromNativeAndGatewayIDs() {
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "kimi-k2.6"), .kimiK26)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "moonshotai/kimi-k2.6"), .kimiK26)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "kimi-k2.7-code"), .kimiK27)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "kimi-k2.7-code-highspeed"), .kimiK27)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "kimi-k2.5"), .kimiK25)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "kimi-k3"), .kimiK3)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "moonshot-v1-32k"), .generic)
    }

    func testOtherLabFamilies() {
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "deepseek-v4-flash"), .deepseek)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "deepseek/deepseek-v4-pro"), .deepseek)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "qwen3.7-max"), .qwen)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "qwen/qwen-plus"), .qwen)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "glm-5.1"), .glm)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "z-ai/glm-5.2"), .glm)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "MiniMax-M2.7"), .minimax)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "minimax/minimax-m2.7"), .minimax)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "gpt-4.1"), .generic)
    }

    func testKimiOmitsSamplingEvenWhenThinkingIsDisabled() {
        for model in ["kimi-k2.6", "moonshotai/kimi-k2.6", "kimi-k3", "kimi-k2.7-code"] {
            XCTAssertTrue(
                ChatCompletionsModelPolicy.shouldOmitSampling(model: model),
                "\(model) must omit the app temperature baseline"
            )
            XCTAssertTrue(
                ChatCompletionsModelPolicy.shouldOmitSampling(model: model, thinkingMode: .disabled)
            )
        }
    }

    func testDeepSeekOmitsSamplingWhileThinkingIsOn() {
        XCTAssertTrue(
            ChatCompletionsModelPolicy.shouldOmitSampling(model: "deepseek-v4-flash")
        )
        XCTAssertTrue(
            ChatCompletionsModelPolicy.shouldOmitSampling(
                model: "deepseek/deepseek-v4-pro",
                thinkingMode: .enabled
            )
        )
        XCTAssertFalse(
            ChatCompletionsModelPolicy.shouldOmitSampling(
                model: "deepseek-v4-flash",
                thinkingMode: .disabled
            )
        )
    }

    func testQwenGLMAndMiniMaxKeepSampling() {
        XCTAssertFalse(ChatCompletionsModelPolicy.shouldOmitSampling(model: "qwen3.7-max"))
        XCTAssertFalse(ChatCompletionsModelPolicy.shouldOmitSampling(model: "glm-5.1"))
        XCTAssertFalse(ChatCompletionsModelPolicy.shouldOmitSampling(model: "MiniMax-M2.7"))
    }

    func testGPT5OmitStillWins() {
        XCTAssertTrue(ChatCompletionsModelPolicy.shouldOmitSampling(model: "gpt-5.5"))
        XCTAssertTrue(ChatCompletionsModelPolicy.shouldOmitSampling(model: "openai/gpt-5.6-sol"))
        XCTAssertFalse(ChatCompletionsModelPolicy.shouldOmitSampling(model: "gpt-5.3-chat-latest"))
    }

    func testKimiK3DoesNotExposeThinkingToggle() {
        XCTAssertFalse(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "kimi-k3"))
        XCTAssertFalse(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "kimi-k2.7-code"))
        XCTAssertTrue(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "kimi-k2.6"))
        XCTAssertFalse(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "gpt-4.1"))
    }

    func testThinkingEncodingForLabs() {
        XCTAssertEqual(
            ChatCompletionsModelPolicy.thinkingEncoding(
                provider: .moonshot,
                model: "kimi-k2.6",
                thinkingMode: .disabled,
                reasoningEffort: nil,
                usesPromptInferenceSettings: false
            ),
            .thinkingType("disabled")
        )
        XCTAssertEqual(
            ChatCompletionsModelPolicy.thinkingEncoding(
                provider: .minimax,
                model: "MiniMax-M2.7",
                thinkingMode: .enabled,
                reasoningEffort: nil,
                usesPromptInferenceSettings: false
            ),
            .thinkingType("adaptive")
        )
        XCTAssertEqual(
            ChatCompletionsModelPolicy.thinkingEncoding(
                provider: .qwen,
                model: "qwen3.7-max",
                thinkingMode: .enabled,
                reasoningEffort: nil,
                usesPromptInferenceSettings: false
            ),
            .enableThinking(true)
        )
        XCTAssertEqual(
            ChatCompletionsModelPolicy.thinkingEncoding(
                provider: .moonshot,
                model: "kimi-k3",
                thinkingMode: .enabled,
                reasoningEffort: nil,
                usesPromptInferenceSettings: false
            ),
            .omit
        )
        XCTAssertEqual(
            ChatCompletionsModelPolicy.thinkingEncoding(
                provider: .moonshot,
                model: "kimi-k2.7-code",
                thinkingMode: .disabled,
                reasoningEffort: nil,
                usesPromptInferenceSettings: false
            ),
            .omit
        )
        XCTAssertEqual(
            ChatCompletionsModelPolicy.thinkingEncoding(
                provider: .openrouter,
                model: "moonshotai/kimi-k2.6",
                thinkingMode: .disabled,
                reasoningEffort: nil,
                usesPromptInferenceSettings: false
            ),
            .omit
        )
    }

    func testGenericOpenAICompatibleKeepsLlamaCppKwargs() {
        XCTAssertEqual(
            ChatCompletionsModelPolicy.thinkingEncoding(
                provider: .openaiCompatible,
                model: "llama-3.1-8b",
                thinkingMode: .disabled,
                reasoningEffort: nil,
                usesPromptInferenceSettings: true
            ),
            .llamaCpp(enableThinking: false, reasoningEffort: nil)
        )
        XCTAssertEqual(
            ChatCompletionsModelPolicy.thinkingEncoding(
                provider: .openaiCompatible,
                model: "kimi-k2.6",
                thinkingMode: .disabled,
                reasoningEffort: nil,
                usesPromptInferenceSettings: true
            ),
            .thinkingType("disabled")
        )
    }
}
