import Foundation

struct ProcessResult {
    let exitCode: Int32
    let output: String       // combined stdout + stderr
}

enum ProcessError: Error, LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return msg
        }
    }
}

/// Runs an external tool, streaming combined stdout/stderr line-by-line.
final class ProcessRunner {
    private let process = Process()
    private let pipe = Pipe()
    private var buffer = Data()
    private let bufferQueue = DispatchQueue(label: "ProcessRunner.buffer")
    private var collected = ""

    let executable: String
    let arguments: [String]

    init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Launches the process and delivers each output line on an arbitrary queue.
    /// Returns when the process exits and output is fully drained.
    @discardableResult
    func run(onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self, !data.isEmpty else { return }
            self.bufferQueue.async {
                self.buffer.append(data)
                self.drainLines(onLine: onLine)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                guard let self else {
                    continuation.resume(returning: ProcessResult(exitCode: proc.terminationStatus, output: ""))
                    return
                }
                handle.readabilityHandler = nil
                // Drain whatever is left.
                let remaining = try? handle.readToEnd()
                self.bufferQueue.async {
                    if let remaining { self.buffer.append(remaining) }
                    self.drainLines(onLine: onLine, flush: true)
                    continuation.resume(returning: ProcessResult(exitCode: proc.terminationStatus,
                                                                 output: self.collected))
                }
            }
            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                continuation.resume(throwing: ProcessError.launchFailed(
                    "Couldn't launch \(executable): \(error.localizedDescription)"))
            }
        }
    }

    /// Must be called on bufferQueue.
    private func drainLines(onLine: (@Sendable (String) -> Void)?, flush: Bool = false) {
        // Tools like makemkvcon/cd-paranoia use \r for progress updates; treat it as a line break.
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer.prefix(upTo: idx)
            buffer.removeSubrange(...idx)
            emit(lineData, onLine: onLine)
        }
        if flush, !buffer.isEmpty {
            emit(buffer, onLine: onLine)
            buffer.removeAll()
        }
    }

    private func emit(_ data: Data, onLine: (@Sendable (String) -> Void)?) {
        guard let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return }
        collected += line + "\n"
        if collected.count > 2_000_000 { collected.removeFirst(collected.count - 2_000_000) }
        onLine?(line)
    }
}

/// One-shot helper for short commands where streaming isn't needed.
@discardableResult
func runCommand(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
    try await ProcessRunner(executable, arguments).run()
}
