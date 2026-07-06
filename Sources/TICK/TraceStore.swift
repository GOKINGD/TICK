import Foundation

struct LLMTokenUsage: Codable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var requestWordCount: Int
    var responseWordCount: Int

    static let empty = LLMTokenUsage(
        promptTokens: nil,
        completionTokens: nil,
        totalTokens: nil,
        requestWordCount: 0,
        responseWordCount: 0
    )

    var computedTotalTokens: Int? {
        if let totalTokens {
            return totalTokens
        }

        if let promptTokens, let completionTokens {
            return promptTokens + completionTokens
        }

        return nil
    }

    var totalWordCount: Int {
        requestWordCount + responseWordCount
    }

    mutating func merge(_ usage: LLMTokenUsage?) {
        guard let usage else {
            return
        }

        promptTokens = add(promptTokens, usage.promptTokens)
        completionTokens = add(completionTokens, usage.completionTokens)
        totalTokens = add(totalTokens, usage.totalTokens)
        requestWordCount += usage.requestWordCount
        responseWordCount += usage.responseWordCount
    }

    private func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            return lhs + rhs
        case (.some(let lhs), .none):
            return lhs
        case (.none, .some(let rhs)):
            return rhs
        case (.none, .none):
            return nil
        }
    }
}

struct TraceEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let traceID: String?
    let stage: String
    let detail: String
    let rawHTTP: String?
    let tokenUsage: LLMTokenUsage?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case traceID
        case stage
        case detail
        case rawHTTP
        case tokenUsage
    }

    init(id: UUID = UUID(), date: Date = Date(), traceID: String? = TraceContext.currentID, stage: String, detail: String, rawHTTP: String? = nil, tokenUsage: LLMTokenUsage? = nil) {
        self.id = id
        self.date = date
        self.traceID = traceID
        self.stage = stage
        self.detail = detail
        self.rawHTTP = rawHTTP
        self.tokenUsage = tokenUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        traceID = try container.decodeIfPresent(String.self, forKey: .traceID)
        stage = try container.decode(String.self, forKey: .stage)
        detail = try container.decode(String.self, forKey: .detail)
        rawHTTP = try container.decodeIfPresent(String.self, forKey: .rawHTTP)
        tokenUsage = try container.decodeIfPresent(LLMTokenUsage.self, forKey: .tokenUsage)
    }
}

enum TraceContext {
    @TaskLocal static var currentID: String?

    static func makeID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "tick-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
    }
}

@MainActor
final class TraceStore: ObservableObject {
    static let shared = TraceStore()

    @Published private(set) var events: [TraceEvent] = []

    private let fileURL: URL
    private let maxEvents = 400
    private let encoder = JSONEncoder()

    private init() {
        encoder.outputFormatting = [.sortedKeys]
        fileURL = TICKRuntime.rootURL.appendingPathComponent("trace.jsonl")
        load()
    }

    func log(_ stage: String, _ detail: String, rawHTTP: String? = nil, tokenUsage: LLMTokenUsage? = nil, traceID: String? = TraceContext.currentID) {
        let event = TraceEvent(traceID: traceID, stage: stage, detail: detail, rawHTTP: rawHTTP, tokenUsage: tokenUsage)
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        appendToDisk(event)
    }

    func clear() {
        events.removeAll()
        try? Data().write(to: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        let decoder = JSONDecoder()
        events = text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else {
                return nil
            }
            return try? decoder.decode(TraceEvent.self, from: data)
        }
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    private func appendToDisk(_ event: TraceEvent) {
        guard let data = try? encoder.encode(event),
              var line = String(data: data, encoding: .utf8) else {
            return
        }

        line.append("\n")
        guard let lineData = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: fileURL)
        }
    }
}

func traceLog(_ stage: String, _ detail: String, rawHTTP: String? = nil, tokenUsage: LLMTokenUsage? = nil, traceID: String? = TraceContext.currentID) {
    Task { @MainActor in
        TraceStore.shared.log(stage, detail, rawHTTP: rawHTTP, tokenUsage: tokenUsage, traceID: traceID)
    }
}
