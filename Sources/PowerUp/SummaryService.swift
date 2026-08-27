import Foundation

/// Produces a short spoken-friendly conclusion of a long reply by shelling
/// out to the `claude` CLI one-shot with a lightweight model — the user's
/// existing login, no API keys, no new dependencies.
///
/// Summaries are a best-effort garnish: every failure mode (binary missing,
/// timeout, empty output, a "summary" longer than the reply) resolves the
/// completion with nil and the caller speaks the full reply as it always did.
/// Only the newest request matters — starting a new one abandons the old.
@MainActor
final class SummaryService: ObservableObject {

    /// Summarization must never hold a reply hostage: past this, give up and
    /// let the caller fall back to speaking the full reply.
    static let timeout: TimeInterval = 30

    /// Bumped per request so a stale process's output is dropped silently.
    private var generation = 0
    private var process: Process?

    /// One-shot, tool-less, text-out invocation. `--permission-mode default`
    /// and a neutral working directory keep the call from ever touching a
    /// project; the prompt asks for prose only.
    nonisolated static func arguments(model: String) -> [String] {
        ["-p", "--model", model, "--output-format", "text", "--permission-mode", "default"]
    }

    nonisolated static func prompt(for reply: String) -> String {
        """
        Summarize the following coding-assistant reply in one or two short \
        sentences meant to be READ ALOUD: what was done or found, and anything \
        the listener must do next. Plain prose only — no markdown, no lists, \
        no preamble. Answer in the same language as the reply.

        Reply to summarize:
        \(reply)
        """
    }

    /// Requests a summary. `completion` is invoked exactly once, on the main
    /// actor: the summary text, or nil when the caller should fall back to
    /// the full reply. A newer `summarize` call silently supersedes this one
    /// (the superseded completion is NOT invoked — its turn is over).
    func summarize(_ reply: String,
                   model: String,
                   claudePathOverride: String?,
                   completion: @escaping (String?) -> Void) {
        cancel()
        generation += 1
        let generation = self.generation

        let prompt = SummaryService.prompt(for: reply)
        let arguments = SummaryService.arguments(model: model)

        Task.detached(priority: .utility) { [weak self] in
            let binary = ClaudeService.resolveClaudeBinary(override: claudePathOverride)
            let summary = binary.flatMap {
                SummaryService.run(binary: $0, arguments: arguments, stdin: prompt)
            }

            // A summary that is empty or not meaningfully shorter than the
            // reply is worse than the reply — treat it as a failure.
            let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usable: String?
            if let trimmed, !trimmed.isEmpty, trimmed.count < max(200, reply.count / 2) {
                usable = trimmed
            } else {
                usable = nil
            }

            guard let service = self else { return }
            await MainActor.run {
                guard service.generation == generation else { return }
                service.process = nil
                completion(usable)
            }
        }
    }

    /// Abandons any in-flight request; its completion never fires.
    func cancel() {
        generation += 1
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    /// Blocking one-shot run with a hard timeout; called off the main actor.
    private nonisolated static func run(binary: String, arguments: [String], stdin: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()

        // Drain stdout concurrently so a chatty process can't fill the pipe
        // and deadlock against our bounded wait. The semaphore orders the
        // box's write before our read.
        final class OutputBox: @unchecked Sendable { var data = Data() }
        let box = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminationHandler = nil
            process.terminate()
            return nil
        }
        guard drained.wait(timeout: .now() + 2) == .success else { return nil }
        guard process.terminationStatus == 0 else { return nil }

        return String(decoding: box.data, as: UTF8.self)
    }
}
