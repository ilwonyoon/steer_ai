import Foundation
import Darwin

struct LocalSteerStore {
    private let databaseURL: URL

    init(databaseURL: URL = LocalSteerStore.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    func loadCards() async -> [ActionCard] {
        await Task.detached {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                return []
            }

            do {
                return try loadDashboardCards(databaseURL: databaseURL)
            } catch {
                guard shouldFallbackToSessionCards(error) else {
                    return []
                }

                do {
                    let sessions: [SessionRow] = try runSQLiteJSON(
                        databaseURL: databaseURL,
                        sql: """
                        SELECT id, provider, adapter_kind, command, cwd, pid, run_state, created_at, updated_at
                        FROM sessions
                        ORDER BY
                          CASE run_state
                            WHEN 'waiting' THEN 0
                            WHEN 'blocked' THEN 1
                            WHEN 'running' THEN 2
                            ELSE 3
                          END,
                          updated_at DESC
                        LIMIT 12;
                        """
                    )

                    return sessions.map { session in
                        let entries = (try? recentTranscriptEntries(for: session.id, databaseURL: databaseURL)) ?? []
                        return makeCard(session: session, entries: entries)
                    }
                } catch {
                    return []
                }
            }
        }.value
    }

    func send(_ text: String, to sessionId: String) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: steerExecutablePath())
            process.arguments = ["send", sessionId, text]
            process.environment = processEnvironment()
            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "steer send failed"
                throw LocalSteerStoreError.commandFailed(message)
            }
        }.value
    }

    static func defaultDatabaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["STEER_DB"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let home = ProcessInfo.processInfo.environment["STEER_HOME"].flatMap { value -> URL? in
            guard !value.isEmpty else { return nil }
            return URL(fileURLWithPath: value)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".steer")

        return home.appendingPathComponent("steer.sqlite")
    }
}

private enum LocalSteerStoreError: Error {
    case commandFailed(String)
}

private func shouldFallbackToSessionCards(_ error: Error) -> Bool {
    guard case LocalSteerStoreError.commandFailed(let message) = error else {
        return false
    }

    return message.localizedCaseInsensitiveContains("no such table: action_cards")
}

private struct SessionRow: Decodable {
    let id: String
    let provider: String
    let adapterKind: String?
    let command: String?
    let cwd: String?
    let pid: Int?
    let runState: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case adapterKind = "adapter_kind"
        case command
        case cwd
        case pid
        case runState = "run_state"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct TranscriptEntryRow: Decodable {
    let id: String
    let stream: String
    let chunk: String
    let timestamp: String
}

private struct ActionCardRow: Decodable {
    let id: String
    let sessionId: String
    let provider: String
    let command: String?
    let cwd: String?
    let pid: Int?
    let runState: String
    let category: String
    let priority: String
    let title: String
    let summary: String
    let actionPrompt: String?
    let optionsJSON: String?
    let displayLinesJSON: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case provider
        case command
        case cwd
        case pid
        case runState = "run_state"
        case category
        case priority
        case title
        case summary
        case actionPrompt = "action_prompt"
        case optionsJSON = "options_json"
        case displayLinesJSON = "display_lines_json"
        case updatedAt = "updated_at"
    }
}

private func loadDashboardCards(databaseURL: URL) throws -> [ActionCard] {
    let actionCards = try loadActionCards(databaseURL: databaseURL)
    let actionSessionIds = Set(actionCards.map(\.sessionId))
    let sessionCards = try loadSessionCards(databaseURL: databaseURL, excluding: actionSessionIds)

    return Array((actionCards + sessionCards).prefix(12))
}

private func loadActionCards(databaseURL: URL) throws -> [ActionCard] {
    let rows: [ActionCardRow] = try runSQLiteJSON(
        databaseURL: databaseURL,
        sql: """
        SELECT
          ac.id,
          ac.session_id,
          s.provider,
          s.command,
          s.cwd,
          s.pid,
          s.run_state,
          ac.category,
          ac.priority,
          ac.title,
          ac.summary,
          ac.action_prompt,
          ac.options_json,
          te.display_lines_json,
          ac.updated_at
        FROM action_cards ac
        JOIN sessions s ON s.id = ac.session_id
        LEFT JOIN terminal_excerpts te ON te.id = ac.terminal_excerpt_id
        WHERE ac.state = 'active'
          AND s.run_state != 'disconnected'
          AND EXISTS (
            SELECT 1
            FROM transcript_entries trusted
            WHERE trusted.session_id = s.id
              AND trusted.stream IN ('report', 'stdout', 'stderr')
          )
        ORDER BY
          CASE ac.priority
            WHEN 'urgent' THEN 0
            WHEN 'normal' THEN 1
            ELSE 2
          END,
          ac.updated_at DESC
        LIMIT 12;
        """
    )

    return rows.filter(isLiveActionCardRow).map(makeCard(row:))
}

private func loadSessionCards(databaseURL: URL, excluding excludedSessionIds: Set<String>) throws -> [ActionCard] {
    let exclusionClause: String
    if excludedSessionIds.isEmpty {
        exclusionClause = ""
    } else {
        let quotedIds = excludedSessionIds
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        exclusionClause = "AND id NOT IN (\(quotedIds))"
    }

    let rows: [SessionRow] = try runSQLiteJSON(
        databaseURL: databaseURL,
        sql: """
        SELECT id, provider, adapter_kind, command, cwd, pid, run_state, created_at, updated_at
        FROM sessions
        WHERE run_state IN ('running', 'waiting', 'blocked')
          \(exclusionClause)
        ORDER BY
          CASE run_state
            WHEN 'waiting' THEN 0
            WHEN 'blocked' THEN 1
            WHEN 'running' THEN 2
            ELSE 3
          END,
          updated_at DESC
        LIMIT 12;
        """
    )

    return rows.filter(isLiveSessionRow).map { session in
        let entries = (try? recentTranscriptEntries(for: session.id, databaseURL: databaseURL)) ?? []
        return makeCard(session: session, entries: entries)
    }
}

private func isLiveActionCardRow(_ row: ActionCardRow) -> Bool {
    guard ["running", "waiting", "blocked"].contains(row.runState) else {
        return true
    }
    return isLiveProcess(pid: row.pid)
}

private func isLiveSessionRow(_ row: SessionRow) -> Bool {
    isLiveProcess(pid: row.pid)
}

private func isLiveProcess(pid: Int?) -> Bool {
    guard let pid, pid > 0 else {
        return true
    }
    return kill(pid_t(pid), 0) == 0
}

private func recentTranscriptEntries(for sessionId: String, databaseURL: URL) throws -> [TranscriptEntryRow] {
    let quotedSessionId = sessionId.replacingOccurrences(of: "'", with: "''")
    let rows: [TranscriptEntryRow] = try runSQLiteJSON(
        databaseURL: databaseURL,
        sql: """
        SELECT id, stream, chunk, timestamp
        FROM transcript_entries
        WHERE session_id = '\(quotedSessionId)'
        ORDER BY timestamp DESC
        LIMIT 360;
        """
    )
    return rows.reversed()
}

private func runSQLiteJSON<T: Decodable>(databaseURL: URL, sql: String) throws -> [T] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = ["-json", databaseURL.path, sql]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        throw LocalSteerStoreError.commandFailed(String(data: error, encoding: .utf8) ?? "sqlite3 failed")
    }

    if output.isEmpty {
        return []
    }

    let decoder = JSONDecoder()
    return try decoder.decode([T].self, from: output)
}

private func makeCard(session: SessionRow, entries: [TranscriptEntryRow]) -> ActionCard {
    let provider = ProviderKind(rawValue: session.provider) ?? .custom
    let state = mapState(session.runState)
    let project = projectName(from: session.cwd)
    let terminalLines = makeTerminalLines(from: entries, allowPtyFallback: true)
    let lastLine = terminalLines.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
    let command = session.command ?? session.provider

    return ActionCard(
        id: session.id,
        sessionId: session.id,
        project: project,
        provider: provider,
        state: state,
        age: state.rawValue,
        title: "\(provider.displayName) · \(command)",
        summary: lastLine ?? "No transcript captured yet.",
        reason: session.cwd ?? "No working directory recorded.",
        terminalLines: terminalLines,
        chips: defaultChips(for: state),
        thread: makeThread(from: entries)
    )
}

private func makeCard(row: ActionCardRow) -> ActionCard {
    let provider = ProviderKind(rawValue: row.provider) ?? .custom
    let state = mapState(row.runState)
    let project = projectName(from: row.cwd)
    let displayLines = decodeStringArray(row.displayLinesJSON)
    let terminalLines = makeTerminalLines(from: displayLines, category: row.category)
    let normalizedSummary = normalizeTerminalDisplayLine(row.summary)
    let summary = isMeaningfulTerminalLine(normalizedSummary)
        ? normalizedSummary
        : terminalLines.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text ?? row.title

    return ActionCard(
        id: row.id,
        sessionId: row.sessionId,
        project: project,
        provider: provider,
        state: state,
        age: state.rawValue,
        title: row.title,
        summary: summary,
        reason: row.actionPrompt ?? row.cwd ?? "No working directory recorded.",
        terminalLines: terminalLines,
        chips: decodeStringArray(row.optionsJSON).ifEmpty(defaultChips(for: state)),
        shouldNotify: isNotifiableActionCategory(row.category),
        thread: []
    )
}

private func isNotifiableActionCategory(_ category: String) -> Bool {
    ["blocker", "decision", "question", "waiting"].contains(category)
}

private func mapState(_ value: String) -> SessionState {
    switch value {
    case "waiting": .waiting
    case "blocked": .blocked
    case "running": .running
    case "ended": .ended
    case "disconnected": .disconnected
    default: .waiting
    }
}

private func projectName(from cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "unknown-project" }
    return URL(fileURLWithPath: cwd).lastPathComponent
}

private func defaultChips(for state: SessionState) -> [String] {
    switch state {
    case .running:
        ["Continue", "Summarize progress", "Pause after current step"]
    case .ended:
        ["Summarize result", "Open next task", "Archive"]
    case .disconnected:
        ["Summarize last output", "Restart later", "Archive"]
    case .blocked:
        ["Use simplest option", "Explain blocker", "Continue"]
    case .waiting:
        ["Continue", "Use your recommendation", "Explain"]
    }
}

private func makeTerminalLines(from entries: [TranscriptEntryRow], allowPtyFallback: Bool = false) -> [TerminalLine] {
    let trustedEntries = trustedActionEntries(from: entries)
    if trustedEntries.isEmpty, allowPtyFallback, let ptyLines = makePtyFallbackTerminalLines(from: entries) {
        return ptyLines
    }
    let rawText = trustedEntries.map(\.chunk).joined()
    let fallbackKind = trustedEntries.last.map { lineKind(for: $0.stream) } ?? .standard
    let lines = terminalDisplayLines(from: rawText)
        .map { line in
            TerminalLine(line, kind: kind(forTerminalLine: line, fallback: fallbackKind))
        }
        .suffix(28)

    if lines.isEmpty {
        return [TerminalLine("[no transcript yet]", kind: .muted)]
    }

    return Array(lines)
}

private func makePtyFallbackTerminalLines(from entries: [TranscriptEntryRow]) -> [TerminalLine]? {
    let ptyText = entries.filter { $0.stream == "pty" }.map(\.chunk).joined()
    guard !ptyText.isEmpty else { return nil }

    let oscMessages = extractOSC9Messages(from: ptyText)
    let oscText = oscMessages.suffix(3).joined(separator: "\n")
    let sourceText = shouldUseOSC9Preview(oscText) ? oscText : ptyText
    let lines = terminalDisplayLines(from: sourceText)
        .map { TerminalLine($0, kind: kind(forTerminalLine: $0, fallback: .standard)) }
        .suffix(28)

    return lines.isEmpty ? nil : Array(lines)
}

private func shouldUseOSC9Preview(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.contains("...") || trimmed.contains("…") {
        return false
    }
    return trimmed.count >= 80
}

private func makeTerminalLines(from displayLines: [String], category: String) -> [TerminalLine] {
    let fallbackKind: TerminalLineKind = switch category {
    case "blocker": .warning
    case "completion": .success
    default: .standard
    }
    let lines = displayLines
        .map { normalizeTerminalDisplayLine($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .filter(isMeaningfulTerminalLine)
        .map { TerminalLine($0, kind: kind(forTerminalLine: $0, fallback: fallbackKind)) }

    return lines.ifEmpty([TerminalLine("[no transcript yet]", kind: .muted)])
}

private func terminalDisplayLines(from rawText: String) -> [String] {
    var text = cleanTerminalText(rawText)
    text = text.replacingOccurrences(
        of: "\\s+([⚠✖✔])\\s*",
        with: "\n$1 ",
        options: .regularExpression
    )
    text = text.replacingOccurrences(
        of: "\\s+([›>])\\s+",
        with: "\n$1 ",
        options: .regularExpression
    )
    text = text.replacingOccurrences(
        of: "([^\\n])›(?=\\S)",
        with: "$1\n›",
        options: .regularExpression
    )
    text = text.replacingOccurrences(
        of: "\\s*(\\[(?:user|steer|codex|claude)\\])",
        with: "\n$1",
        options: [.regularExpression, .caseInsensitive]
    )
    text = text.replacingOccurrences(
        of: "\\s{2,}(gpt-[\\w.-]+[^\\n]*·[^\\n]*)",
        with: "\n$1",
        options: .regularExpression
    )

    let lines = text
        .components(separatedBy: .newlines)
        .flatMap(splitTerminalDisplayLine)
        .map { normalizeTerminalDisplayLine($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .filter(isMeaningfulTerminalLine)

    return Array(lines.suffix(28))
}

private func makeThread(from entries: [TranscriptEntryRow]) -> [ThreadMessage] {
    entries
        .filter { $0.stream != "pty" }
        .suffix(12)
        .compactMap { entry in
            let text = cleanTerminalText(entry.chunk).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ThreadMessage(
                id: entry.id,
                sender: entry.stream == "user" ? .user : .agent,
                text: text
            )
        }
}

private func lineKind(for stream: String) -> TerminalLineKind {
    switch stream {
    case "user": .accent
    case "stderr": .warning
    case "system": .muted
    default: .standard
    }
}

private func trustedActionEntries(from entries: [TranscriptEntryRow]) -> [TranscriptEntryRow] {
    let reportEntries = entries.filter { $0.stream == "report" }
    if !reportEntries.isEmpty {
        return reportEntries
    }

    let semanticEntries = entries.filter { entry in
        entry.stream != "pty" && entry.stream != "system" && entry.stream != "user"
    }
    if !semanticEntries.isEmpty {
        return semanticEntries
    }

    return []
}

private func kind(forTerminalLine line: String, fallback: TerminalLineKind) -> TerminalLineKind {
    if line.contains("⚠") || line.localizedCaseInsensitiveContains("failed") || line.localizedCaseInsensitiveContains("error") {
        return .warning
    }
    if line.localizedCaseInsensitiveContains("어려워요") || line.localizedCaseInsensitiveContains("blocked") {
        return .warning
    }
    if line.localizedCaseInsensitiveContains("complete") || line.localizedCaseInsensitiveContains("success") {
        return .success
    }
    if line.localizedCaseInsensitiveContains("쉬워요") || line.localizedCaseInsensitiveContains("saved") {
        return .success
    }
    if line.hasPrefix("›") || line.hasPrefix(">") {
        return .accent
    }
    if line.hasSuffix("?") || line.hasSuffix("까요?") {
        return .accent
    }
    if line.range(of: "^(Decision needed|Next|Question|Blocked|옵션\\s*\\d+):?", options: [.regularExpression, .caseInsensitive]) != nil {
        return .accent
    }
    if line.hasPrefix("•") || line.hasPrefix("- ") || line.hasPrefix("* ") {
        return .muted
    }
    if line.hasPrefix("gpt-") {
        return .muted
    }
    return fallback
}

private func cleanTerminalText(_ value: String) -> String {
    var cleaned = value
    let patterns = [
        "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
        "\u{001B}[PX^_][\\s\\S]*?\u{001B}\\\\",
        "\u{001B}\\[[0-?]*[ -/]*[@-~]",
        "\u{001B}[@-Z\\\\-_]",
        "[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}\u{007F}]"
    ]

    for pattern in patterns {
        cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    return cleaned.replacingOccurrences(of: "\r", with: "\n")
}

private func extractOSC9Messages(from value: String) -> [String] {
    var messages: [String] = []
    var searchStart = value.startIndex

    while let markerRange = value.range(of: "\u{001B}]9;", range: searchStart..<value.endIndex) {
        let payloadStart = markerRange.upperBound
        let terminatorRange = value[payloadStart...].firstIndex { character in
            character == "\u{0007}" || character == "\u{001B}"
        }
        guard let terminatorRange else { break }

        let payload = String(value[payloadStart..<terminatorRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !payload.isEmpty {
            messages.append(payload)
        }

        searchStart = value.index(after: terminatorRange)
    }

    return messages
}

private func splitTerminalDisplayLine(_ line: String) -> [String] {
    line
        .replacingOccurrences(
            of: "\\s+(gpt-[\\w.-]+[^\\n]*·[^\\n]*)",
            with: "\n$1",
            options: .regularExpression
        )
        .components(separatedBy: .newlines)
}

private func collapseTerminalWhitespace(_ value: String) -> String {
    value.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
}

private func normalizeTerminalDisplayLine(_ value: String) -> String {
    collapseTerminalWhitespace(
        value.replacingOccurrences(
            of: "\\?•Work(?:ing)?\\b.*$",
            with: "?",
            options: [.regularExpression, .caseInsensitive]
        )
    )
}

private func isMeaningfulTerminalLine(_ line: String) -> Bool {
    guard !line.isEmpty else { return false }
    guard line.range(of: "[A-Za-z0-9가-힣⚠✖✔›>]", options: .regularExpression) != nil else {
        return false
    }
    if line.range(of: "^\\s*(?:\\[user\\]|\\[steer\\])", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "^\\s*›", options: .regularExpression) != nil {
        return false
    }
    if line.range(of: "^gpt-[\\w.-]+.*·", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "^\\s*[A-Za-z]{1,2}\\s*$", options: .regularExpression) != nil {
        return false
    }
    if line.range(of: "^\\]1[01];\\?\\\\?$", options: .regularExpression) != nil {
        return false
    }
    if line.range(of: "^Tip: Try the Codex App", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "^https://chatgpt.com/codex", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "Under-development features enabled", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "features are incomplete", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "suppress_unstable_features_warning", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "config.toml", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "MCP client for `?pencil`? failed", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "MCP startup failed", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "No such file or direc", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "os error 2", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "MCP startup incomplete", options: .caseInsensitive) != nil {
        return false
    }
    if line.localizedCaseInsensitiveContains("esc to interr") {
        return false
    }
    if line.localizedCaseInsensitiveContains("esc again to edit previous message") {
        return false
    }
    if line.localizedCaseInsensitiveContains("tab to queue message") {
        return false
    }
    if line.range(of: "auto mode on", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "shift\\+tab", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "esc to interrupt", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "tokens?\\)", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "running stop hooks", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "Worked for", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "Cultivating", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "Crunching", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "\\*?Worked for \\d+", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "\\*?Baked for \\d+", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "^\\d+$", options: .regularExpression) != nil {
        return false
    }
    if line.range(of: "Starting MCP servers", options: .caseInsensitive) != nil {
        return false
    }
    if line.range(of: "SStt|WWoorr|MMCC|rrvv|sseerr", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "(Working[•. ]*){2,}", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "^Wo•Wor", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "xcodebui.*xcodebuild.*•", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if line.range(of: "/model\\s+choose what model", options: [.regularExpression, .caseInsensitive]) != nil,
       line.range(of: "/permissions", options: .caseInsensitive) != nil {
        return false
    }
    if line.count > 80,
       line.range(of: "codex_a|xcodebui|xcodebuildmcp|context left", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    return true
}

private func decodeStringArray(_ value: String?) -> [String] {
    guard let value, let data = value.data(using: .utf8) else {
        return []
    }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
}

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] {
        isEmpty ? fallback : self
    }
}

private func steerExecutablePath() -> String {
    let candidates = [
        "/opt/homebrew/bin/steer",
        "/usr/local/bin/steer"
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "steer"
}

private func processEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = [environment["PATH"], defaultPath].compactMap(\.self).joined(separator: ":")
    return environment
}
