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
                return []
            }
        }.value
    }

    func loadLiveSessions(excluding excludedSessionIds: Set<String>) async -> [LiveSessionChip] {
        await Task.detached {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                return []
            }

            do {
                return try loadLiveSessionChips(databaseURL: databaseURL, excluding: excludedSessionIds)
            } catch {
                return []
            }
        }.value
    }

    func send(_ text: String, to sessionId: String) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: steerExecutablePath())
            process.arguments = ["send", sessionId, text]
            process.environment = processEnvironment()
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
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
    try loadActionCards(databaseURL: databaseURL)
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
          AND ac.category IN ('blocker', 'decision', 'question', 'waiting')
          AND (
            s.run_state IN ('waiting', 'blocked')
            OR (
              s.run_state = 'running'
              AND NOT EXISTS (
                SELECT 1
                FROM transcript_entries traffic
                WHERE traffic.session_id = s.id
                  AND traffic.stream IN ('report', 'stdout', 'stderr', 'pty', 'user')
              )
            )
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

private func isLiveActionCardRow(_ row: ActionCardRow) -> Bool {
    guard ["running", "waiting", "blocked"].contains(row.runState) else {
        return true
    }
    return isLiveProcess(pid: row.pid)
}

private struct LiveSessionRow: Decodable {
    let sessionId: String
    let provider: String
    let cwd: String?
    let pid: Int?
    let runState: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "id"
        case provider
        case cwd
        case pid
        case runState = "run_state"
        case updatedAt = "updated_at"
    }
}

private func loadLiveSessionChips(databaseURL: URL, excluding excludedSessionIds: Set<String>) throws -> [LiveSessionChip] {
    let exclusionClause: String
    if excludedSessionIds.isEmpty {
        exclusionClause = ""
    } else {
        let quotedIds = excludedSessionIds
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        exclusionClause = "AND id NOT IN (\(quotedIds))"
    }

    let rows: [LiveSessionRow] = try runSQLiteJSON(
        databaseURL: databaseURL,
        sql: """
        SELECT id, provider, cwd, pid, run_state, updated_at
        FROM sessions
        WHERE run_state IN ('running', 'waiting', 'blocked')
          \(exclusionClause)
        ORDER BY updated_at DESC
        LIMIT 24;
        """
    )

    return rows
        .filter { isLiveProcess(pid: $0.pid) }
        .map(makeLiveSessionChip(row:))
}

private func makeLiveSessionChip(row: LiveSessionRow) -> LiveSessionChip {
    LiveSessionChip(
        sessionId: row.sessionId,
        provider: ProviderKind(rawValue: row.provider) ?? .custom,
        project: projectName(from: row.cwd),
        cwd: row.cwd,
        runState: row.runState,
        lastActivityAt: parseISODate(row.updatedAt) ?? Date()
    )
}

private func parseISODate(_ value: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: value) {
        return date
    }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

private func isLiveProcess(pid: Int?) -> Bool {
    guard let pid, pid > 0 else {
        return true
    }
    return kill(pid_t(pid), 0) == 0
}

private func runSQLiteJSON<T: Decodable>(databaseURL: URL, sql: String) throws -> [T] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = ["-cmd", ".timeout 1000", "-json", databaseURL.path, sql]
    process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

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

private func makeCard(row: ActionCardRow) -> ActionCard {
    let provider = ProviderKind(rawValue: row.provider) ?? .custom
    let state = mapState(row.runState)
    let project = projectName(from: row.cwd)
    let displayLines = decodeStringArray(row.displayLinesJSON)
    let terminalLines = makeTerminalLines(from: displayLines)
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
        category: row.category,
        accentHue: hueForCwd(row.cwd),
        branchLabel: gitBranchLabel(for: row.cwd),
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

private func gitBranchLabel(for cwd: String?) -> String? {
    guard let cwd, !cwd.isEmpty else { return nil }
    let fm = FileManager.default
    var current = URL(fileURLWithPath: cwd).standardizedFileURL

    for _ in 0..<32 {
        let dotGit = current.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
            let gitDir: URL
            if isDir.boolValue {
                gitDir = dotGit
            } else {
                guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
                let prefix = "gitdir:"
                let trimmed = contents.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
                guard trimmed.hasPrefix(prefix) else { return nil }
                let path = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                gitDir = URL(fileURLWithPath: path)
            }

            return readBranchLabel(gitDir: gitDir, worktreeURL: current)
        }

        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { return nil }
        current = parent
    }
    return nil
}

private func readBranchLabel(gitDir: URL, worktreeURL: URL) -> String? {
    let head = gitDir.appendingPathComponent("HEAD")
    guard let raw = try? String(contentsOf: head, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    let worktreeName = gitDir.path.contains("/worktrees/") ? gitDir.lastPathComponent : nil

    if trimmed.hasPrefix("ref: refs/heads/") {
        let branch = String(trimmed.dropFirst("ref: refs/heads/".count))
        if let worktreeName, worktreeName != branch {
            return "\(branch) · \(worktreeName)"
        }
        return branch
    }

    let shortHash = String(trimmed.prefix(7))
    if let worktreeName {
        return "(\(shortHash)) · \(worktreeName)"
    }
    return "(\(shortHash))"
}

private func hueForCwd(_ cwd: String?) -> Double {
    guard let cwd, !cwd.isEmpty else { return 0 }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in cwd.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    let goldenStep = 137.508
    let bucket = Double(hash % 1024)
    return (bucket * goldenStep).truncatingRemainder(dividingBy: 360)
}

private func projectName(from cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "unknown-project" }
    let url = URL(fileURLWithPath: cwd)
    let last = url.lastPathComponent
    let parent = url.deletingLastPathComponent().lastPathComponent
    if parent.isEmpty || parent == "/" || last.isEmpty {
        return last.isEmpty ? "unknown-project" : last
    }
    return "\(parent)/\(last)"
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

private func makeTerminalLines(from displayLines: [String]) -> [TerminalLine] {
    let fallbackKind: TerminalLineKind = .standard
    let normalizedLines = displayLines.map { normalizeTerminalDisplayLine($0) }
    var lines: [TerminalLine] = []

    for (index, line) in normalizedLines.enumerated() {
        if isMeaningfulTerminalLine(line) {
            lines.append(TerminalLine(line, kind: kind(forTerminalLine: line, fallback: fallbackKind)))
            continue
        }

        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !lines.isEmpty,
           lines.last?.text.isEmpty == false,
           normalizedLines[(index + 1)...].contains(where: isMeaningfulTerminalLine) {
            lines.append(TerminalLine("", kind: .muted))
        }
    }

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

private func kind(forTerminalLine line: String, fallback: TerminalLineKind) -> TerminalLineKind {
    if line.hasPrefix("> ") || line.hasPrefix("›") {
        return .accent
    }
    if line.hasPrefix("```") {
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
    value.replacingOccurrences(
        of: "\\?•Work(?:ing)?\\b.*$",
        with: "?",
        options: [.regularExpression, .caseInsensitive]
    )
    .trimmingCharacters(in: .newlines)
}

private func isMeaningfulTerminalLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    guard trimmed.range(of: "[A-Za-z0-9가-힣⚠✖✔›>]", options: .regularExpression) != nil else {
        return false
    }
    if trimmed.range(of: "^(?:\\[user\\]|\\[steer\\])", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "^›", options: .regularExpression) != nil {
        return false
    }
    if trimmed.range(of: "^gpt-[\\w.-]+.*·", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "^[A-Za-z]{1,2}$", options: .regularExpression) != nil {
        return false
    }
    if trimmed.range(of: "^\\]1[01];\\?\\\\?$", options: .regularExpression) != nil {
        return false
    }
    if trimmed.range(of: "^Tip: Try the Codex App", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "^https://chatgpt.com/codex", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "Under-development features enabled", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "features are incomplete", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "suppress_unstable_features_warning", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "config.toml", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "MCP client for `?pencil`? failed", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "MCP startup failed", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "No such file or direc", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "os error 2", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "MCP startup incomplete", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.localizedCaseInsensitiveContains("esc to interr") {
        return false
    }
    if trimmed.localizedCaseInsensitiveContains("esc again to edit previous message") {
        return false
    }
    if trimmed.localizedCaseInsensitiveContains("tab to queue message") {
        return false
    }
    if trimmed.range(of: "auto mode on", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "shift\\+tab", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "esc to interrupt", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "tokens?\\)", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "running stop hooks", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "Worked for", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "Cultivating", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "Crunching", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "\\*?Worked for \\d+", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "\\*?Baked for \\d+", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "^\\d+$", options: .regularExpression) != nil {
        return false
    }
    if trimmed.range(of: "Starting MCP servers", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.range(of: "SStt|WWoorr|MMCC|rrvv|sseerr", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "(Working[•. ]*){2,}", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "^Wo•Wor", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "xcodebui.*xcodebuild.*•", options: [.regularExpression, .caseInsensitive]) != nil {
        return false
    }
    if trimmed.range(of: "/model\\s+choose what model", options: [.regularExpression, .caseInsensitive]) != nil,
       trimmed.range(of: "/permissions", options: .caseInsensitive) != nil {
        return false
    }
    if trimmed.count > 80,
       trimmed.range(of: "codex_a|xcodebui|xcodebuildmcp|context left", options: [.regularExpression, .caseInsensitive]) != nil {
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
