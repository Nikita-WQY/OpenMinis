import Foundation

private let logger = AppLogger(category: "ChatImport")

// MARK: - Parsed export model

/// A single message parsed from a Kelivo chat export.
struct ParsedChatMessage {
    let roleName: String
    let timestamp: Date?
    let text: String
}

/// Result of parsing a Kelivo chat export file.
struct ParsedChatExport {
    let title: String?
    let messages: [ParsedChatMessage]
    /// Distinct role names in order of first appearance (for the "which one is you?" picker).
    let roleNames: [String]
}

// MARK: - Kelivo export parser

/// Parses chat exports produced by Kelivo's "export as Markdown / TXT" feature.
///
/// Format (verified against a real 132-message export):
///
///     # Conversation title
///
///     > 2026年8月10日 15:19:51 · RoleName
///
///     message body…
///
///     ---
///
///     > next header…
///
/// Caveats handled here:
/// - The timestamp is device-locale formatted ("2026年8月10日 15:19:51" on Chinese
///   devices, "2026-08-10 15:19:51" otherwise), so both forms are accepted.
/// - `---` also legitimately appears inside message bodies (markdown horizontal
///   rule). A separator only ends a message when the following non-blank line is
///   another `> time · role` header; otherwise it is restored into the body.
/// - Images are embedded as base64 data URIs (can be megabytes); they are
///   replaced with a short placeholder instead of being imported.
enum KelivoChatExportParser {
    static func parse(_ raw: String) -> ParsedChatExport {
        // "> {timestamp} · {roleName}" — non-greedy so a "·" inside the role name stays with the role.
        let headerRegex = try! NSRegularExpression(pattern: "^> (.+?) · (.+)$")
        let imageRegex = try! NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(data:[^)]*\\)")

        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")

        var title: String?
        var startIndex = 0
        while startIndex < lines.count,
              lines[startIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            startIndex += 1
        }
        if startIndex < lines.count, lines[startIndex].hasPrefix("# ") {
            title = String(lines[startIndex].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            startIndex += 1
        }

        struct BuildingMessage {
            var roleName: String
            var timestampRaw: String
            var lines: [String]
        }
        var building: [BuildingMessage] = []
        var pendingSeparator = false

        for line in lines[startIndex...] {
            let fullRange = NSRange(line.startIndex..., in: line)
            if let match = headerRegex.firstMatch(in: line, range: fullRange),
               let tsRange = Range(match.range(at: 1), in: line),
               let nameRange = Range(match.range(at: 2), in: line) {
                building.append(BuildingMessage(
                    roleName: String(line[nameRange]).trimmingCharacters(in: .whitespaces),
                    timestampRaw: String(line[tsRange]),
                    lines: []
                ))
                pendingSeparator = false
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                pendingSeparator = true
                continue
            }
            guard !building.isEmpty else { continue }
            if pendingSeparator && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                building[building.count - 1].lines.append("---")
                pendingSeparator = false
            }
            building[building.count - 1].lines.append(line)
        }

        var messages: [ParsedChatMessage] = []
        var roleNames: [String] = []
        for item in building {
            var content = item.lines.joined(separator: "\n")
            content = imageRegex.stringByReplacingMatches(
                in: content,
                range: NSRange(content.startIndex..., in: content),
                withTemplate: "[图片]"
            )
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !roleNames.contains(item.roleName) {
                roleNames.append(item.roleName)
            }
            messages.append(ParsedChatMessage(
                roleName: item.roleName,
                timestamp: parseTimestamp(item.timestampRaw),
                text: content
            ))
        }
        return ParsedChatExport(title: title, messages: messages, roleNames: roleNames)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let patterns = [
            "(\\d{4})年(\\d{1,2})月(\\d{1,2})日 (\\d{1,2}):(\\d{2}):(\\d{2})",
            "(\\d{4})-(\\d{1,2})-(\\d{1,2}) (\\d{1,2}):(\\d{2}):(\\d{2})",
        ]
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            let fullRange = NSRange(raw.startIndex..., in: raw)
            guard let match = regex.firstMatch(in: raw, range: fullRange) else { continue }
            func group(_ index: Int) -> Int? {
                guard let range = Range(match.range(at: index), in: raw) else { return nil }
                return Int(raw[range])
            }
            guard let year = group(1), let month = group(2), let day = group(3),
                  let hour = group(4), let minute = group(5), let second = group(6) else { continue }
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            if let date = calendar.date(from: components) { return date }
        }
        return nil
    }
}

// MARK: - Importer

/// Writes a parsed Kelivo export into a brand-new local session so the
/// conversation renders as normal chat bubbles and can be continued in place.
/// Mirrors SessionForkManager.duplicateSession: createSession → RawMessages →
/// append → .sessionDidCreate.
@MainActor
final class ChatHistoryImporter {
    static let shared = ChatHistoryImporter()
    private init() {}

    /// ChatStore prunes sessions above 2048 messages; stay under it so freshly
    /// imported history isn't immediately deleted.
    private static let maxImportedMessages = 2000

    /// - Parameters:
    ///   - userRoleName: the parsed role name whose messages become `.user`
    ///     (everything else becomes `.assistant`).
    ///   - modelId: model bound to the new session.
    func importExport(
        _ export: ParsedChatExport,
        userRoleName: String,
        modelId: String
    ) async -> ChatSession? {
        var incoming = export.messages.filter { !$0.text.isEmpty }
        if incoming.count > Self.maxImportedMessages {
            logger.info("[Import] \(incoming.count) messages exceed cap; keeping most recent \(Self.maxImportedMessages)")
            incoming = Array(incoming.suffix(Self.maxImportedMessages))
        }
        guard !incoming.isEmpty else {
            logger.error("[Import] No non-empty messages to import")
            return nil
        }

        let store = ChatStore.shared
        let title = (export.title?.isEmpty == false) ? export.title! : "导入的聊天"
        let session = await store.createSession(modelId: modelId, title: title)

        // createdAt drives more than display: ChatStore.repairSessionIfNeeded
        // rewrites sort_order to canonical (created_at, id) order on session
        // open. Kelivo timestamps have 1-second resolution, so a question and
        // its reply often share a second — with random UUIDs that "repair"
        // swaps roughly half of such pairs. Keep createdAt strictly increasing
        // (ties bumped by 10ms, invisible in UI) so canonical order always
        // equals file order. Missing/unparsable timestamps fall back to
        // previous + 1s.
        var rawMessages: [RawMessage] = []
        var lastTimestamp = (incoming.first?.timestamp ?? Date()).addingTimeInterval(-1)
        for message in incoming {
            var timestamp = message.timestamp ?? lastTimestamp.addingTimeInterval(1)
            if timestamp <= lastTimestamp {
                timestamp = lastTimestamp.addingTimeInterval(0.01)
            }
            lastTimestamp = timestamp
            rawMessages.append(RawMessage(
                id: UUID().uuidString,
                sessionId: session.id,
                role: message.roleName == userRoleName ? .user : .assistant,
                parts: [.text(message.text)],
                createdAt: timestamp,
                tokenUsage: nil,
                reasoningContent: nil,
                streamInterruptCount: 0
            ))
        }

        await store.appendMessages(rawMessages)
        logger.info("[Import] Imported \(rawMessages.count) messages into session \(session.id)")
        NotificationCenter.default.post(name: .sessionDidCreate, object: session.id)
        return session
    }
}
