import Foundation

// MARK: - Crash Info
/// Represents detailed information about a crash event.
public struct CrashInfo: Codable, Sendable {
    public let timestamp: Date
    public let reason: String
    public let callStack: [String]
    public let signalInfo: String?
    public let appVersion: String
    public let osVersion: String
    
    public var description: String {
        var desc = "=== CRASH REPORT ===\n"
        desc += "Timestamp: \(timestamp)\n"
        desc += "App Version: \(appVersion)\n"
        desc += "OS Version: \(osVersion)\n"
        desc += "Reason: \(reason)\n"
        if let signal = signalInfo {
            desc += "Signal: \(signal)\n"
        }
        desc += "Call Stack:\n"
        desc += callStack.joined(separator: "\n")
        return desc
    }
}

// MARK: - Wappn
/// The main class for the Wappn package, handling crash detection and log interception.
///
/// Use `Wappn.shared` to access the singleton instance.
public final class Wappn: @unchecked Sendable {
    public static let shared = Wappn()
    
    private var capturedOutput: [String] = []
    private var crashInfo: CrashInfo?
    private let queue = DispatchQueue(label: "com.wappn.interceptor", attributes: .concurrent)
    private var originalStdout: Int32 = -1
    private var pipe: [Int32] = [-1, -1]
    private var isIntercepting = false
    
    // Crash storage keys
    private let crashFileURL: URL
    
    // Crash handler callback
    /// Callback triggered when a crash occurs.
    ///
    /// This closure is called just before the app terminates due to a crash.
    /// You can use this to save critical data, but keep the operation short.
    public var onCrash: (@Sendable (CrashInfo) -> Void)?
    
    private init() {
        // Setup crash file path
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        crashFileURL = documents.appendingPathComponent("last_crash.json")
    }
    
    // MARK: - Public Methods
    
    /// Check if app crashed in previous session
    public func didCrashLastTime() -> Bool {
        return FileManager.default.fileExists(atPath: crashFileURL.path)
    }
    
    /// Get crash info from previous session
    public func getLastCrashInfo() -> CrashInfo? {
        // Try to load from file first (most detailed)
        if let data = try? Data(contentsOf: crashFileURL),
           let crash = try? JSONDecoder().decode(CrashInfo.self, from: data) {
            return crash
        }
                
        return nil
    }
    
    /// Clear crash marker - call after handling previous crash
    public func clearCrashMarker() {
        try? FileManager.default.removeItem(at: crashFileURL)
    }
    
    /// Mark app as successfully launched
    public func markLaunchSuccess() {
        clearCrashMarker()
    }
    
    /// Get the path where crash files are stored
    public func getCrashFilePath() -> String {
        return crashFileURL.path
    }
    
    /// Starts intercepting standard output and monitoring for crashes.
    ///
    /// - Parameter interceptCrashes: If `true`, sets up handlers for uncaught exceptions and fatal signals.
    public func startIntercepting(interceptCrashes: Bool = true) {
        queue.sync(flags: .barrier) {
            guard !isIntercepting else { return }
            
            // Save original stdout
            originalStdout = dup(STDOUT_FILENO)
            
            // Create pipe
            Darwin.pipe(&pipe)
            
            // Redirect stdout to pipe write end
            dup2(pipe[1], STDOUT_FILENO)
            close(pipe[1])
            
            isIntercepting = true
            
            // Start reading from pipe in background
            let pipeReadEnd = pipe[0]
            let originalStdoutCopy = originalStdout
            
            DispatchQueue.global(qos: .background).async { [weak self] in
                self?.readFromPipe(pipeReadEnd: pipeReadEnd, originalStdout: originalStdoutCopy)
            }
            
            // Setup crash handlers
            if interceptCrashes {
                setupCrashHandlers()
            }
        }
    }
    
    /// Stops intercepting standard output and restores the original stdout.
    public func stopIntercepting() {
        queue.sync(flags: .barrier) {
            guard isIntercepting else { return }
            
            // Restore original stdout
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            if pipe[0] >= 0 {
                close(pipe[0])
            }
            
            isIntercepting = false
        }
    }
    
    /// Returns all captured output strings.
    ///
    /// - Returns: An array of strings captured from stdout.
    public func getCapturedOutput() -> [String] {
        return queue.sync {
            return capturedOutput
        }
    }
    
    /// Returns the crash info if a crash has been detected in the current session.
    ///
    /// This is typically populated just before the app terminates.
    /// - Returns: `CrashInfo` if a crash occurred, otherwise `nil`.
    public func getCrashInfo() -> CrashInfo? {
        return queue.sync {
            return crashInfo
        }
    }
    
    /// Clears all captured output and crash info.
    public func clearCapturedOutput() {
        queue.async(flags: .barrier) { [weak self] in
            self?.capturedOutput.removeAll()
            self?.crashInfo = nil
        }
    }
    
    // MARK: - Private Methods
    
    private func readFromPipe(pipeReadEnd: Int32, originalStdout: Int32) {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        var shouldContinue = true
        while shouldContinue {
            // Check if we should continue reading in a thread-safe way
            shouldContinue = queue.sync { isIntercepting }
            guard shouldContinue else { break }
            
            let bytesRead = read(pipeReadEnd, &buffer, bufferSize)
            
            guard bytesRead > 0 else { break }
            
            // Write to original stdout (so it still prints)
            _ = write(originalStdout, buffer, bytesRead)
            
            // Capture the output
            if let output = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                queue.async(flags: .barrier) { [weak self] in
                    self?.capturedOutput.append(output)
                }
            }
        }
    }
    
    // MARK: - Crash Handling
    
    private func setupCrashHandlers() {
        // NSException handler (for Objective-C exceptions)
        // Note: This only catches NSExceptions, not Swift runtime errors
        NSSetUncaughtExceptionHandler { exception in
            print("⚠️ Uncaught NSException detected: \(exception.reason ?? "Unknown")")
            let crash = CrashInfo(
                timestamp: Date(),
                reason: exception.reason ?? "Unknown exception",
                callStack: exception.callStackSymbols,
                signalInfo: nil,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
            let shared = Wappn.shared
            shared.handleCrash(crash)
        }
        
        // Signal handlers for fatal signals
        // SIGTRAP: Essential for Swift runtime errors (precondition failures, force unwraps, etc.)
        // SIGABRT: Abort signals (often from assertions)
        // SIGILL: Illegal instruction
        // SIGSEGV: Segmentation fault (memory access violations)
        // SIGFPE: Floating point exceptions
        // SIGBUS: Bus error (memory alignment issues)
        // SIGPIPE: Broken pipe (writing to closed pipe/socket)
        // SIGXCPU: CPU time limit exceeded
        // SIGXFSZ: File size limit exceeded
        // SIGSYS: Bad system call (invalid syscall)
        let signals: [Int32] = [SIGTRAP, SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE, SIGXCPU, SIGXFSZ, SIGSYS]
        for sig in signals {
            signal(sig) { signal in
                let shared = Wappn.shared
                let signalName = shared.signalName(for: signal)
                let crash = CrashInfo(
                    timestamp: Date(),
                    reason: "Signal received",
                    callStack: Thread.callStackSymbols,
                    signalInfo: signalName,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString
                )
                shared.handleCrash(crash)
                
                // Re-raise signal to allow system crash handler
                Darwin.signal(signal, SIG_DFL)
                raise(signal)
            }
        }
    }
    
    private func handleCrash(_ crash: CrashInfo) {
        // CRITICAL: Save crash info FIRST - this is the most important operation
        saveCrashInfo(crash)
        
        // Store crash info and get originalStdout synchronously (no async!)
        let stdoutCopy = queue.sync(flags: .barrier) { () -> Int32 in
            self.crashInfo = crash
            // Log crash to captured output
            self.capturedOutput.append("\n" + crash.description + "\n")
            return self.originalStdout
        }
        
        // Call user callback synchronously - this is the last chance!
        onCrash?(crash)
        
        // Also write to original stdout
        if stdoutCopy >= 0 {
            let crashDesc = crash.description
            _ = crashDesc.withCString { ptr in
                write(stdoutCopy, ptr, strlen(ptr))
            }
        }
        print("⚠️ Wappn detected a crash: \(crash.reason)")
        
        // Force flush to disk AFTER writing everything
        fflush(stdout)
        fflush(stderr)
        sync() // Force all pending disk writes
    }
    
    private func syncFileDescriptor(_ fileDescriptor: Int32) {
        if fileDescriptor >= 0 {
            // Force sync to physical disk - CRITICAL for crash persistence
            fsync(fileDescriptor)
            close(fileDescriptor)
        }
    }
    
    private func writeAtomic(data: Data) throws {
        
        // Method 1: Try atomic write first
        try data.write(to: crashFileURL, options: [.atomic])
        
        // CRITICAL: Open file in READ-WRITE mode for fsync (not O_RDONLY!)
        let fileDescriptor = open(crashFileURL.path, O_RDWR)
        syncFileDescriptor(fileDescriptor)
        print("✅ Crash info saved to: \(crashFileURL.path)")
    }
    
    private func writeLowLevel(data: Data) throws {
        // Method 2: Try direct file descriptor write (more reliable in crash)
        let fileDescriptor = open(crashFileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fileDescriptor >= 0 {
            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress, bytes.count > 0 else {
                    return
                }
                _ = write(fileDescriptor, baseAddress, bytes.count)
            }
            syncFileDescriptor(fileDescriptor)
            print("✅ Crash info saved via low-level write: \(crashFileURL.path)")
        } else {
            throw NSError(domain: "Wappn", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open file descriptor"])
        }
    }
        
    private func saveCrashInfo(_ crash: CrashInfo) {
        // CRITICAL: Use most reliable write method in crash scenario
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        guard let data = try? encoder.encode(crash) else {
            print("❌ Failed to encode crash info")
            return
        }
        
        // Try atomic write first, fallback to low-level write if it fails
        do {
            try writeAtomic(data: data)
        } catch {
            print("⚠️ Atomic write failed, trying low-level write: \(error)")
            do {
                try writeLowLevel(data: data)
            } catch {
                print("❌ All write methods failed: \(error)")
            }
        }
    }
    
    private func signalName(for signal: Int32) -> String {
        switch signal {
        case SIGTRAP: return "SIGTRAP (Swift Runtime Error)"
        case SIGABRT: return "SIGABRT (Abort)"
        case SIGILL: return "SIGILL (Illegal Instruction)"
        case SIGSEGV: return "SIGSEGV (Segmentation Fault)"
        case SIGFPE: return "SIGFPE (Floating Point Exception)"
        case SIGBUS: return "SIGBUS (Bus Error)"
        case SIGPIPE: return "SIGPIPE (Broken Pipe)"
        case SIGXCPU: return "SIGXCPU (CPU Time Limit Exceeded)"
        case SIGXFSZ: return "SIGXFSZ (File Size Limit Exceeded)"
        case SIGSYS: return "SIGSYS (Bad System Call)"
        default: return "Signal \(signal)"
        }
    }
}

// MARK: - Enhanced Logger with Interception

/// Log levels for the enhanced logger.
public enum LogLevel: String {
    case debug = "🔍 DEBUG"
    case info = "ℹ️ INFO"
    case warning = "⚠️ WARNING"
    case error = "❌ ERROR"
    case verbose = "💬 VERBOSE"
}

#if !DEBUG
    @inlinable
    @inline(__always)
#endif
/// Logs a message with a specific log level.
///
/// - Parameters:
///   - level: The severity level of the log.
///   - items: The items to log.
///   - separator: The separator between items. Default is a space.
///   - terminator: The string to append after the log. Default is a newline.
///   - file: The file name where the log originated.
///   - line: The line number where the log originated.
///   - function: The function name where the log originated.
public func log(_ level: LogLevel,
                _ items: Any...,
                separator: String = " ",
                terminator: String = "\n",
                file: String = #file,
                line: Int = #line,
                function: String = #function) {
    #if DEBUG
    let fileName = (file as NSString).lastPathComponent
    let output = items.map { "\($0)" }.joined(separator: separator)
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(timestamp)] \(level.rawValue) [\(fileName):\(line)] \(function) - \(output)", terminator: terminator)
    #endif
}

#if !DEBUG
@inlinable
@inline(__always)
#endif
/// Logs a debug message.
///
/// - Parameters:
///   - items: The items to log.
///   - separator: The separator between items. Default is a space.
///   - terminator: The string to append after the log. Default is a newline.
public func logd(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    log(.debug, output, separator: "", terminator: terminator, file: file, line: line, function: function)
    #endif
}

#if !DEBUG
@inlinable
@inline(__always)
#endif
/// Logs an info message.
///
/// - Parameters:
///   - items: The items to log.
///   - separator: The separator between items. Default is a space.
///   - terminator: The string to append after the log. Default is a newline.
public func logi(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    log(.info, output, separator: "", terminator: terminator, file: file, line: line, function: function)
    #endif
}

#if !DEBUG
@inlinable
@inline(__always)
#endif
/// Logs a warning message.
///
/// - Parameters:
///   - items: The items to log.
///   - separator: The separator between items. Default is a space.
///   - terminator: The string to append after the log. Default is a newline.
public func logw(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    log(.warning, output, separator: "", terminator: terminator, file: file, line: line, function: function)
    #endif
}

#if !DEBUG
@inlinable
@inline(__always)
#endif
/// Logs an error message.
///
/// - Parameters:
///   - items: The items to log.
///   - separator: The separator between items. Default is a space.
///   - terminator: The string to append after the log. Default is a newline.
public func loge(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    log(.error, output, separator: "", terminator: terminator, file: file, line: line, function: function)
    #endif
}
#if !DEBUG
@inlinable
@inline(__always)
#endif
/// Logs a verbose message.
///
/// - Parameters:
///   - items: The items to log.
///   - separator: The separator between items. Default is a space.
///   - terminator: The string to append after the log. Default is a newline.
public func logv(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    log(.verbose, output, separator: "", terminator: terminator, file: file, line: line, function: function)
    #endif
}

