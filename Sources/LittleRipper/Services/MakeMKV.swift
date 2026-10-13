import Foundation

/// Thin wrapper around `makemkvcon` robot mode (`-r`).
struct MakeMKV {
    let binary: String

    struct TitleInfo {
        let id: Int
        var name: String = ""
        var durationSeconds: Int = 0
        var chapters: Int = 0
    }

    enum MakeMKVError: Error, LocalizedError {
        case driveNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .driveNotFound:
                return "MakeMKV couldn't see this drive. Is the disc still inserted?"
            case .commandFailed(let msg):
                return msg
            }
        }
    }

    /// Maps a BSD device (disk4) to MakeMKV's disc index by parsing DRV: lines.
    func discIndex(forBSDName bsdName: String) async throws -> Int {
        let result = try await runCommand(binary, ["-r", "--cache=1", "info", "disc:9999"])
        // DRV:0,2,999,12,"BD-RE ...","VOLUME","/dev/rdisk4"
        for line in result.output.split(separator: "\n") where line.hasPrefix("DRV:") {
            let fields = parseRobotFields(String(line.dropFirst(4)))
            guard fields.count >= 7, let index = Int(fields[0]), let visible = Int(fields[1]),
                  visible > 0 else { continue }
            let device = fields[6]
            if device.hasSuffix("/\(bsdName)") || device.hasSuffix("/r\(bsdName)") {
                return index
            }
        }
        throw MakeMKVError.driveNotFound
    }

    /// Lists titles on a source (`disc:N`, `file:<folder>`, or `iso:<file>`) so we can
    /// pick the main feature.
    func titles(source: String, onLine: (@Sendable (String) -> Void)? = nil) async throws -> [TitleInfo] {
        let result = try await ProcessRunner(binary, ["-r", "--cache=1", "info", source]).run(onLine: onLine)
        var titles: [Int: TitleInfo] = [:]
        for line in result.output.split(separator: "\n") where line.hasPrefix("TINFO:") {
            let fields = parseRobotFields(String(line.dropFirst(6)))
            guard fields.count >= 4, let titleID = Int(fields[0]), let attr = Int(fields[1]) else { continue }
            var info = titles[titleID] ?? TitleInfo(id: titleID)
            let value = fields[3]
            switch attr {
            case 2: info.name = value                       // ap_iaName
            case 8: info.chapters = Int(value) ?? 0         // ap_iaChapterCount
            case 9: info.durationSeconds = Self.seconds(from: value)  // ap_iaDuration "1:39:03"
            default: break
            }
            titles[titleID] = info
        }
        return titles.values.sorted { $0.id < $1.id }
    }

    /// Rips one title (or all) to MKV from a source (`disc:N` or `file:<folder>`).
    func ripToMKV(source: String, title: String, minLengthSeconds: Int, outputDir: URL,
                  onStart: @escaping (ProcessRunner) -> Void,
                  onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        let args = ["-r", "--progress=-same", "--minlength=\(minLengthSeconds)",
                    "mkv", source, title, outputDir.path]
        try await run(args: args, onStart: onStart, onProgress: onProgress)
    }

    /// Full decrypted backup of the disc structure (BDMV / VIDEO_TS). `source` is a
    /// disc source such as `dev:/dev/rdisk4` or `disc:0`. Note: backup requires a
    /// `disc:` source, so callers pass the enumerated index here.
    func backup(source: String, outputDir: URL,
                onStart: @escaping (ProcessRunner) -> Void,
                onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        let args = ["-r", "--progress=-same", "--decrypt",
                    "backup", source, outputDir.path]
        try await run(args: args, onStart: onStart, onProgress: onProgress)
    }

    private func run(args: [String], onStart: @escaping (ProcessRunner) -> Void,
                     onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        let proc = ProcessRunner(binary, args)
        onStart(proc)
        let stageBox = StageBox()
        let result = try await proc.run { line in
            if line.hasPrefix("PRGV:") {
                // PRGV:current,total,max
                let parts = line.dropFirst(5).split(separator: ",")
                if parts.count == 3, let total = Double(parts[1]), let max = Double(parts[2]), max > 0 {
                    onProgress(total / max, stageBox.stage)
                }
            } else if line.hasPrefix("PRGT:") || line.hasPrefix("PRGC:") {
                // PRGT:code,id,"Saving to MKV file"
                let fields = parseRobotFields(String(line.dropFirst(5)))
                if fields.count >= 3, !fields[2].isEmpty {
                    stageBox.stage = fields[2]
                    onProgress(-1, fields[2])   // -1 = stage update only
                }
            } else if line.hasPrefix("MSG:") {
                let fields = parseRobotFields(String(line.dropFirst(4)))
                if fields.count >= 4 {
                    onProgress(-1, fields[3])
                }
            }
        }
        guard result.exitCode == 0 else {
            throw MakeMKVError.commandFailed(Self.friendlyError(from: result.output))
        }
        // makemkvcon can exit 0 while individual titles fail; check the summary.
        if let failed = Self.failedCount(from: result.output), failed > 0 {
            throw MakeMKVError.commandFailed("MakeMKV reported \(failed) failed title(s). Check the disc for scratches and try again.")
        }
    }

    private final class StageBox: @unchecked Sendable {
        var stage: String = "Ripping"
    }

    private static func failedCount(from output: String) -> Int? {
        // MSG:5004,...,"N titles saved, M failed"
        for line in output.split(separator: "\n").reversed() {
            if let m = try? #/(\d+) titles? saved, (\d+) failed/#.firstMatch(in: String(line)) {
                return Int(m.2)
            }
        }
        return nil
    }

    private static func friendlyError(from output: String) -> String {
        let lines = output.split(separator: "\n")
        if let regLine = lines.first(where: { $0.contains("registration key") || $0.contains("expired") }),
           let msg = extractMessage(String(regLine)) {
            return msg + " — open the MakeMKV app once to enter or refresh the (free while in beta) key."
        }
        if let errLine = lines.last(where: { $0.hasPrefix("MSG:") && ($0.contains("Error") || $0.contains("error") || $0.contains("Fail") || $0.contains("fail")) }),
           let msg = extractMessage(String(errLine)) {
            return msg
        }
        return "MakeMKV exited with an error."
    }

    private static func extractMessage(_ line: String) -> String? {
        guard line.hasPrefix("MSG:") else { return String(line) }
        let fields = parseRobotFields(String(line.dropFirst(4)))
        return fields.count >= 4 ? fields[3] : nil
    }

    private static func seconds(from string: String) -> Int {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        return parts.reversed().enumerated().reduce(0) { acc, pair in
            acc + pair.element * Int(pow(60.0, Double(pair.offset)))
        }
    }
}

/// Splits a makemkvcon robot-mode line into fields, honoring quoted strings.
func parseRobotFields(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var iterator = line.makeIterator()
    while let ch = iterator.next() {
        switch ch {
        case "\"":
            inQuotes.toggle()
        case "\\" where inQuotes:
            if let escaped = iterator.next() { current.append(escaped) }
        case "," where !inQuotes:
            fields.append(current)
            current = ""
        default:
            current.append(ch)
        }
    }
    fields.append(current)
    return fields
}
