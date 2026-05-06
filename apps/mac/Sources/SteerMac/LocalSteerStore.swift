import Foundation

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
                let sessions: [SessionRow] = try runSQLiteJSON(
                    databaseURL: databaseURL,
                    sql: """
                    SELECT id, provider, adapter_kind, command, cwd, run_state, created_at, updated_at
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

private struct SessionRow: Decodable {
    let id: String
    let provider: String
    let adapterKind: String?
    let command: String?
    let cwd: String?
    let runState: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case adapterKind = "adapter_kind"
        case command
        case cwd
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

private func recentTranscriptEntries(for sessionId: String, databaseURL: URL) throws -> [TranscriptEntryRow] {
    let quotedSessionId = sessionId.replacingOccurrences(of: "'", with: "''")
    let rows: [TranscriptEntryRow] = try runSQLiteJSON(
        databaseURL: databaseURL,
        sql: """
        SELECT id, stream, chunk, timestamp
        FROM transcript_entries
        WHERE session_id = '\(quotedSessionId)'
        ORDER BY timestamp DESC
        LIMIT 24;
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
    let terminalLines = makeTerminalLines(from: entries)
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

private func makeTerminalLines(from entries: [TranscriptEntryRow]) -> [TerminalLine] {
    let lines = entries
        .flatMap { entry in
            entry.chunk
                .components(separatedBy: .newlines)
                .map { rawLine in
                    TerminalLine(cleanTerminalText(rawLine), kind: lineKind(for: entry.stream))
                }
        }
        .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .suffix(28)

    if lines.isEmpty {
        return [TerminalLine("[no transcript yet]", kind: .muted)]
    }

    return Array(lines)
}

private func makeThread(from entries: [TranscriptEntryRow]) -> [ThreadMessage] {
    entries
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

private func cleanTerminalText(_ value: String) -> String {
    let withoutANSI = value.replacingOccurrences(
        of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
        with: "",
        options: .regularExpression
    )
    return withoutANSI.replacingOccurrences(of: "\r", with: "")
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
