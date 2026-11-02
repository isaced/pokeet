import PokeetCore

enum BrandIcon {
    static func assetName(
        for provider: ProviderConfiguration,
        model: ProviderModel? = nil
    ) -> String? {
        let candidates = [
            model?.id,
            model?.displayName,
            provider.name,
            provider.baseURL
        ]
        .compactMap { $0?.lowercased() }
        .filter { !$0.isEmpty }

        for candidate in candidates {
            if let asset = assetName(in: candidate) {
                return asset
            }
        }
        return nil
    }

    private static func assetName(in value: String) -> String? {
        let patterns: [(keys: [String], asset: String)] = [
            (["deepseek"], "brand-deepseek"),
            (["anthropic", "claude"], "brand-anthropic"),
            (["gemini", "generativelanguage", "google"], "brand-googlegemini"),
            (["kimi", "moonshot"], "brand-kimi"),
            (["qwen", "tongyi", "dashscope"], "brand-qwen"),
            (["minimax"], "brand-minimax"),
            (["mistral"], "brand-mistralai"),
            (["llama", "meta-llama"], "brand-meta"),
            (["zdotai", "z.ai", "zhipu", "glm"], "brand-zdotai"),
            (["xiaomi"], "brand-xiaomi"),
            (["spacex"], "brand-spacex"),
            (["openai", "chatgpt", "gpt-", "gpt4", "o1-", "o3-", "o4-"], "brand-openai")
        ]

        for pattern in patterns {
            if pattern.keys.contains(where: { value.contains($0) }) {
                return pattern.asset
            }
        }
        return nil
    }
}
