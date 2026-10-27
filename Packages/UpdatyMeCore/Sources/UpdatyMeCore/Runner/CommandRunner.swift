import Foundation
import Synchronization

/// Einzige Schnittstelle für externe Programmaufrufe. Provider bekommen einen `CommandRunning`
/// injiziert, damit Tests einen Mock mit Fixtures verwenden können.
public protocol CommandRunning: Sendable {
    /// Startet den Aufruf und liefert die Ausgabe zeilenweise. Der Stream endet mit `.completed`
    /// oder wirft einen `CommandError`. Abbrechen des konsumierenden Tasks beendet den Prozess.
    func stream(_ command: Command) async -> AsyncThrowingStream<CommandEvent, any Error>
}

extension CommandRunning {
    /// Führt den Aufruf aus und wartet auf das Ergebnis.
    public func run(_ command: Command) async throws -> CommandResult {
        for try await event in await stream(command) {
            if case .completed(let result) = event {
                return result
            }
        }
        try Task.checkCancellation()
        throw CommandError.noResult(command: command.description)
    }
}

/// Führt Programme über `Process` aus: Argument-Array, Timeout, zeilenweises Streaming.
public actor CommandRunner: CommandRunning {
    private var executions: [UUID: ProcessExecution] = [:]

    public init() {}

    /// Anzahl der aktuell laufenden Prozesse.
    public var runningCount: Int { executions.count }

    public func stream(_ command: Command) -> AsyncThrowingStream<CommandEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<CommandEvent, any Error>.makeStream()
        let id = UUID()
        let execution = ProcessExecution(command: command, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            execution.cancel()
            Task { await self?.remove(id) }
        }
        do {
            try execution.start()
            executions[id] = execution
        } catch {
            continuation.finish(throwing: error)
        }
        return stream
    }

    /// Beendet alle laufenden Prozesse (z. B. beim Beenden der App).
    public func cancelAll() {
        for execution in executions.values {
            execution.cancel()
        }
    }

    private func remove(_ id: UUID) {
        executions[id] = nil
    }
}

/// Ein einzelner laufender Prozess. Der Stream wird beendet, sobald der Prozess terminiert ist
/// und beide Pipes geschlossen sind – oder spätestens `pipeGracePeriod` nach dem Prozessende,
/// falls Kindprozesse die Pipes offen halten.
final class ProcessExecution: Sendable {
    private enum Channel { case stdout, stderr }

    private struct State {
        var stdout = Data()
        var stderr = Data()
        var stdoutPending = Data()
        var stderrPending = Data()
        var stdoutClosed = false
        var stderrClosed = false
        var exitCode: Int32?
        var finished = false
        var timedOut = false
    }

    private enum Outcome {
        case completed(CommandResult)
        case failed(CommandError)
    }

    static let killGracePeriod: Duration = .seconds(2)
    static let pipeGracePeriod: Duration = .seconds(2)

    private let command: Command
    private let continuation: AsyncThrowingStream<CommandEvent, any Error>.Continuation
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let state = Mutex(State())

    init(command: Command, continuation: AsyncThrowingStream<CommandEvent, any Error>.Continuation) {
        self.command = command
        self.continuation = continuation
    }

    func start() throws {
        let path = command.executable.path
        guard command.executable.isFileURL, path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else {
            throw CommandError.invalidExecutable(path)
        }

        process.executableURL = command.executable
        process.arguments = command.arguments
        if let environment = command.environment {
            process.environment = environment
        }
        if let workingDirectory = command.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            receive(handle.availableData, on: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            receive(handle.availableData, on: .stderr)
        }
        process.terminationHandler = { [self] process in
            didTerminate(exitCode: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw CommandError.launchFailed(command: command.description, reason: error.localizedDescription)
        }

        let timeout = command.timeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.didTimeOut()
        }
    }

    /// Beendet den Prozess (SIGTERM, nach Karenzzeit SIGKILL). Ohne Wirkung, wenn er bereits beendet ist.
    func cancel() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task { [weak self] in
            try? await Task.sleep(for: Self.killGracePeriod)
            if let self, self.process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Ereignisse

    private func receive(_ data: Data, on channel: Channel) {
        var lines: [String] = []
        let outcome: Outcome? = state.withLock { state in
            guard !state.finished else { return nil }
            if data.isEmpty {
                switch channel {
                case .stdout:
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    state.stdoutClosed = true
                    lines = Self.flush(&state.stdoutPending)
                case .stderr:
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    state.stderrClosed = true
                    lines = Self.flush(&state.stderrPending)
                }
                return Self.outcomeIfDone(&state)
            }
            switch channel {
            case .stdout:
                state.stdout.append(data)
                state.stdoutPending.append(data)
                lines = Self.completeLines(from: &state.stdoutPending)
            case .stderr:
                state.stderr.append(data)
                state.stderrPending.append(data)
                lines = Self.completeLines(from: &state.stderrPending)
            }
            return nil
        }
        for line in lines {
            continuation.yield(channel == .stdout ? .stdoutLine(line) : .stderrLine(line))
        }
        deliver(outcome)
    }

    private func didTerminate(exitCode: Int32) {
        let outcome: Outcome? = state.withLock { state in
            state.exitCode = exitCode
            return Self.outcomeIfDone(&state)
        }
        deliver(outcome)
        guard outcome == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.pipeGracePeriod)
            self?.finishIgnoringOpenPipes()
        }
    }

    private func didTimeOut() {
        let outcome: Outcome? = state.withLock { state in
            guard !state.finished, state.exitCode == nil else { return nil }
            state.finished = true
            state.timedOut = true
            return .failed(.timedOut(
                command: command.description,
                timeout: command.timeout,
                partialStdout: String(decoding: state.stdout, as: UTF8.self),
                partialStderr: String(decoding: state.stderr, as: UTF8.self)
            ))
        }
        guard outcome != nil else { return }
        cancel()
        deliver(outcome)
    }

    private func finishIgnoringOpenPipes() {
        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        let outcome: Outcome? = state.withLock { state in
            guard !state.finished else { return nil }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutLines = Self.flush(&state.stdoutPending)
            stderrLines = Self.flush(&state.stderrPending)
            state.stdoutClosed = true
            state.stderrClosed = true
            return Self.outcomeIfDone(&state)
        }
        stdoutLines.forEach { continuation.yield(.stdoutLine($0)) }
        stderrLines.forEach { continuation.yield(.stderrLine($0)) }
        deliver(outcome)
    }

    /// Wird außerhalb des Locks aufgerufen, weil `finish` synchron `onTermination` → `cancel()` auslöst.
    private func deliver(_ outcome: Outcome?) {
        switch outcome {
        case .completed(let result):
            continuation.yield(.completed(result))
            continuation.finish()
        case .failed(let error):
            continuation.finish(throwing: error)
        case nil:
            break
        }
    }

    // MARK: - Hilfsfunktionen

    private static func outcomeIfDone(_ state: inout State) -> Outcome? {
        guard !state.finished, state.stdoutClosed, state.stderrClosed, let exitCode = state.exitCode else {
            return nil
        }
        state.finished = true
        return .completed(CommandResult(
            exitCode: exitCode,
            stdout: String(decoding: state.stdout, as: UTF8.self),
            stderr: String(decoding: state.stderr, as: UTF8.self)
        ))
    }

    /// Entnimmt alle vollständigen Zeilen. Das Trennen am Byte `\n` ist UTF-8-sicher.
    private static func completeLines(from buffer: inout Data) -> [String] {
        guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = buffer[buffer.startIndex..<lastNewline]
        buffer = Data(buffer[buffer.index(after: lastNewline)...])
        return complete
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private static func flush(_ buffer: inout Data) -> [String] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
    }
}
