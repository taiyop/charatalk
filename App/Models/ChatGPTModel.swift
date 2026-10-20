import Foundation

/// A ChatGPT model as returned by the account-specific model catalog.
///
/// `slug` is the value sent as `model` for inference; `displayName` is the
/// value shown in the model picker.
public struct ChatGPTModel: Identifiable, Sendable, Equatable {
    public let slug: String
    public let displayName: String

    public var id: String { slug }

    public init(slug: String, displayName: String) {
        self.slug = slug
        self.displayName = displayName
    }
}

public enum ChatGPTModelCatalogError: Error, LocalizedError, Equatable, Sendable {
    /// The response was not the official `{ "models": [...] }` catalog envelope.
    case invalidResponse
    case unauthorized
    case forbidden
    case rateLimited
    case server(statusCode: Int)
    case unexpectedStatus(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "モデル一覧の応答を読み取れませんでした。時間をおいて一覧を更新してください。"
        case .unauthorized:
            return "ChatGPT の認証が無効または期限切れです。もう一度サインインしてください。"
        case .forbidden:
            return "この ChatGPT アカウントではモデル一覧を取得できません。アカウントの権限を確認してください。"
        case .rateLimited:
            return "モデル一覧の取得が集中しています。しばらく待ってからもう一度お試しください。"
        case .server(let statusCode):
            return "ChatGPT のサーバーで一時的なエラーが発生しました (HTTP \(statusCode))。時間をおいてもう一度お試しください。"
        case .unexpectedStatus(let statusCode):
            return "モデル一覧を取得できませんでした (HTTP \(statusCode))。時間をおいてもう一度お試しください。"
        }
    }
}

/// Fetches and filters the account-specific ChatGPT model catalog.
///
/// The catalog is intentionally not hardcoded: the signed-in account's server
/// response is the only source of available models and of the fallback model.
public enum ChatGPTModelCatalog {
    private static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!

    /// Decodes the official `{ "models": [{ "slug", "display_name", "visibility", ... }] }`
    /// envelope, keeping only displayable models in server order.
    public static func decode(_ data: Data) throws -> [ChatGPTModel] {
        let envelope: ModelsEnvelope
        do {
            envelope = try JSONDecoder().decode(ModelsEnvelope.self, from: data)
        } catch {
            // In particular, the API-key shape `{ "object": "list", "data": [...] }`
            // is not this catalog envelope.
            throw ChatGPTModelCatalogError.invalidResponse
        }

        var seen = Set<String>()
        var models: [ChatGPTModel] = []
        for entry in envelope.models {
            guard entry.visibility == "list", let rawSlug = entry.slug else { continue }

            let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty else { continue }
            guard seen.insert(slug).inserted else { continue }

            let rawDisplayName = entry.displayName ?? ""
            let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? slug
                : rawDisplayName
            models.append(ChatGPTModel(slug: slug, displayName: displayName))
        }
        return models
    }

    /// Keeps an exact (trimmed) preferred slug when the catalog still offers it,
    /// otherwise selects the first server-provided model. Returns `nil` only
    /// when the catalog is empty.
    public static func selectedSlug(preferred: String, models: [ChatGPTModel]) -> String? {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, models.contains(where: { $0.slug == trimmed }) {
            return trimmed
        }
        return models.first?.slug
    }

    /// Fetches the model catalog with the OAuth access token.
    ///
    /// Status failures are mapped to actionable errors without exposing the
    /// response body. An account with no displayable models yields `[]`.
    public static func fetch(accessToken: String, session: URLSession = .shared) async throws -> [ChatGPTModel] {
        var request = URLRequest(url: modelsEndpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTModelCatalogError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            return try decode(data)
        case 401:
            throw ChatGPTModelCatalogError.unauthorized
        case 403:
            throw ChatGPTModelCatalogError.forbidden
        case 429:
            throw ChatGPTModelCatalogError.rateLimited
        case 500...599:
            throw ChatGPTModelCatalogError.server(statusCode: http.statusCode)
        default:
            throw ChatGPTModelCatalogError.unexpectedStatus(statusCode: http.statusCode)
        }
    }

    private struct ModelsEnvelope: Decodable {
        let models: [ModelEntry]
    }

    private struct ModelEntry: Decodable {
        let slug: String?
        let displayName: String?
        let visibility: String?

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case visibility
        }
    }
}
