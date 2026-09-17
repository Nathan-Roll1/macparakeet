import Foundation

/// Chat Completions families whose sampling or thinking wire shape differs
/// from generic OpenAI. Detection is by canonical model ID so native lab
/// providers, OpenRouter prefixes (`moonshotai/kimi-k2.6`), and custom
/// OpenAI-compatible endpoints share one policy.
enum ChatCompletionsModelFamily: Equatable, Sendable {
    case kimiK3
    case kimiK27
    case kimiK26
    case kimiK25
    case deepseek
    case qwen
    case glm
    case minimax
    case generic
}

/// Wire encoding for an explicit thinking-mode request. `omit` means the
/// adapter must not send a thinking field (provider default applies, or the
/// model rejects the field).
enum ChatCompletionsThinkingEncoding: Equatable, Sendable {
    case omit
    case thinkingType(String)
    case enableThinking(Bool)
    case llamaCpp(enableThinking: Bool, reasoningEffort: String?)
}

/// Shared Chat Completions request policy. Callers pass a model ID; they do
/// not need to know which provider or gateway served it.
enum ChatCompletionsModelPolicy {
    static func canonicalModelID(_ model: String) -> String {
        OpenAIModelPolicy.canonicalModelID(model)
    }

    static func family(for model: String) -> ChatCompletionsModelFamily {
        let id = canonicalModelID(model)
        if id.hasPrefix("kimi-k3") { return .kimiK3 }
        if id.hasPrefix("kimi-k2.7") { return .kimiK27 }
        if id.hasPrefix("kimi-k2.6") { return .kimiK26 }
        if id.hasPrefix("kimi-k2.5") { return .kimiK25 }
        if isDeepSeekFamily(id) { return .deepseek }
        if isGLMFamily(id) { return .glm }
        if isMiniMaxFamily(id) { return .minimax }
        if isQwenFamily(id) { return .qwen }
        return .generic
    }

    /// Kimi K2.5+ and K3 fix temperature/`top_p`; any other value 400s.
    /// DeepSeek V4 thinking (the default) ignores temperature, so sending the
    /// app baseline would lie on the receipt. GPT-5 / o-series omission stays
    /// in `OpenAIModelPolicy`.
    static func shouldOmitSampling(
        model: String,
        thinkingMode: PromptInferenceSettings.ThinkingMode = .providerDefault
    ) -> Bool {
        if OpenAIModelPolicy.shouldOmitSampling(model: model) { return true }
        switch family(for: model) {
        case .kimiK3, .kimiK27, .kimiK26, .kimiK25:
            return true
        case .deepseek:
            // V4 thinking (the default) ignores temperature. Older chat IDs
            // still sample, including OpenRouter `deepseek/deepseek-chat`.
            if thinkingMode == .disabled { return false }
            return canonicalModelID(model).hasPrefix("deepseek-v4")
        case .qwen, .glm, .minimax, .generic:
            return false
        }
    }

    /// Whether the prompt-settings UI should offer a thinking toggle.
    static func supportsThinkingToggle(model: String) -> Bool {
        switch family(for: model) {
        case .kimiK3, .kimiK27:
            return false
        case .minimax:
            return !canonicalModelID(model).hasPrefix("minimax-m2")
        case .kimiK26, .kimiK25, .deepseek, .qwen, .glm:
            return true
        case .generic:
            return false
        }
    }

    /// Hosted lab Chat Completions endpoints. Custom OpenAI-compatible
    /// URLs that match these hosts get the same thinking wire as the
    /// first-class provider; localhost llama.cpp / vLLM do not.
    static func isKnownChinaLabHost(_ url: URL) -> Bool {
        switch url.host?.lowercased() {
        case "api.moonshot.ai", "api.moonshot.cn",
            "api.deepseek.com",
            "dashscope-intl.aliyuncs.com", "dashscope.aliyuncs.com",
            "api.z.ai", "open.bigmodel.cn",
            "api.minimax.io", "api.minimaxi.com":
            return true
        default:
            return false
        }
    }

    static func usesLabThinkingEncoding(provider: LLMProviderID, baseURL: URL) -> Bool {
        if provider.isChinaLabCloud { return true }
        return provider == .openaiCompatible && isKnownChinaLabHost(baseURL)
    }

    static func thinkingEncoding(
        provider: LLMProviderID,
        model: String,
        baseURL: URL,
        thinkingMode: PromptInferenceSettings.ThinkingMode,
        reasoningEffort: PromptInferenceSettings.ReasoningEffort?,
        usesPromptInferenceSettings: Bool
    ) -> ChatCompletionsThinkingEncoding {
        if provider == .lmstudio || provider == .openrouter {
            return .omit
        }

        if usesLabThinkingEncoding(provider: provider, baseURL: baseURL) {
            return labThinkingEncoding(
                family: family(for: model), model: model, thinkingMode: thinkingMode)
        }

        let usesLlamaCppKwargs =
            provider == .openaiCompatible
            && usesPromptInferenceSettings
            && !OpenAIModelPolicy.requiresMaxCompletionTokens(model: model)
        guard usesLlamaCppKwargs else { return .omit }
        switch thinkingMode {
        case .providerDefault:
            return .omit
        case .enabled:
            return .llamaCpp(enableThinking: true, reasoningEffort: reasoningEffort?.rawValue)
        case .disabled:
            return .llamaCpp(enableThinking: false, reasoningEffort: nil)
        }
    }

    private static func labThinkingEncoding(
        family: ChatCompletionsModelFamily,
        model: String,
        thinkingMode: PromptInferenceSettings.ThinkingMode
    ) -> ChatCompletionsThinkingEncoding {
        switch family {
        case .kimiK3, .kimiK27, .generic:
            // K3 has no thinking field. K2.7-code always thinks; an explicit
            // `disabled` 400s, and `enabled` is only legal with keep=all.
            return .omit
        case .kimiK26, .kimiK25, .deepseek, .glm:
            switch thinkingMode {
            case .providerDefault:
                return .omit
            case .enabled:
                return .thinkingType("enabled")
            case .disabled:
                return .thinkingType("disabled")
            }
        case .minimax:
            // M2.x accepts `disabled` but keeps thinking on. Only M3 honors it.
            if canonicalModelID(model).hasPrefix("minimax-m2") {
                return .omit
            }
            switch thinkingMode {
            case .providerDefault:
                return .omit
            case .enabled:
                return .thinkingType("adaptive")
            case .disabled:
                return .thinkingType("disabled")
            }
        case .qwen:
            switch thinkingMode {
            case .providerDefault:
                return .omit
            case .enabled:
                return .enableThinking(true)
            case .disabled:
                return .enableThinking(false)
            }
        }
    }

    private static func isDeepSeekFamily(_ id: String) -> Bool {
        id.hasPrefix("deepseek-")
    }

    private static func isGLMFamily(_ id: String) -> Bool {
        id.hasPrefix("glm-")
    }

    private static func isMiniMaxFamily(_ id: String) -> Bool {
        id.hasPrefix("minimax-")
    }

    private static func isQwenFamily(_ id: String) -> Bool {
        id.hasPrefix("qwen")
    }
}
