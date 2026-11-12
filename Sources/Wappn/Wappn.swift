import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Crash Info
/// Represents detailed information about a crash event, including stack traces and system diagnostics.
public struct CrashInfo: Codable, Sendable, CustomStringConvertible {
    /// The exact timestamp when the crash occurred.
    public let timestamp: Date
    /// A human-readable description of the crash cause or exception reason.
    public let reason: String
    /// The captured stack trace symbol list at the moment of the crash.
    public let callStack: [String]
    /// Optional signal diagnostic string (e.g., "SIGTRAP", "SIGSEGV").
    public let signalInfo: String?
    /// The short version string of the host application.
    public let appVersion: String
    /// The operating system version string on the host device.
    public let osVersion: String
    
    /// A human-readable multi-line summary of the crash report.
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
    private let maxLogCapacity = 1000 // Maximum number of log lines to keep
    private var crashInfo: CrashInfo?
    private let lock = NSLock() // For thread-safe access to mutable properties
    private var originalStdout: Int32 = -1
    private var pipe: [Int32] = [-1, -1]
    private var isIntercepting = false
    
    // Crash storage keys
    internal let crashFileURL: URL
    internal let tombstoneURL: URL
    
    // Cached metadata for signal-safe access
    nonisolated(unsafe) private static var _appVersion: String = "Unknown"
    nonisolated(unsafe) private static var _osVersion: String = "Unknown"
    
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
        tombstoneURL = documents.appendingPathComponent("crash_tombstone.txt")
        
        // Cache metadata at startup (safe to do here)
        Self._appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        Self._osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        
        // Check for pending tombstone from previous crash
        recoverFromTombstone()
    }
    
    // MARK: - Public Methods
    
    /// Checks if the app crashed in a previous session.
    ///
    /// - Returns: `true` if a crash marker file exists on disk, `false` otherwise.
    public func didCrashLastTime() -> Bool {
        return FileManager.default.fileExists(atPath: crashFileURL.path)
    }
    
    /// Retrieves the decoded crash report from the previous session, if one was recorded.
    ///
    /// - Returns: The previously recorded `CrashInfo`, or `nil` if no crash occurred.
    public func getLastCrashInfo() -> CrashInfo? {
        // Try to load from file first (most detailed)
        if let data = try? Data(contentsOf: crashFileURL),
           let crash = try? JSONDecoder().decode(CrashInfo.self, from: data) {
            return crash
        }
                
        return nil
    }
    
    /// Clears the persisted crash marker file. Call this after handling a previous crash report.
    public func clearCrashMarker() {
        try? FileManager.default.removeItem(at: crashFileURL)
    }
    
    /// Marks the current application launch as successful by clearing any pending crash markers.
    public func markLaunchSuccess() {
        clearCrashMarker()
    }
    
    /// Returns the filesystem path where the crash report JSON is persisted.
    ///
    /// - Returns: The absolute path string to the crash report file.
    public func getCrashFilePath() -> String {
        return crashFileURL.path
    }
    
    /// Ignores the POSIX `SIGPIPE` signal across the entire host process.
    ///
    /// ### Why this is required (Quoting Apple Documentation)
    /// According to Apple's **Networking and Multitasking Technical Note** & **BSD Sockets Documentation**:
    /// > *"By default, a `SIGPIPE` signal is sent to the process when a write to a socket or pipe fails
    /// > because the other end has closed the connection. The default action for `SIGPIPE` is to terminate
    /// > the process. If your application writes to a socket that has been closed by the peer (such as a remote
    /// > server disconnecting while in background), your application will terminate immediately unless you
    /// > tell the system to ignore `SIGPIPE`."*
    ///
    /// > *"To prevent `SIGPIPE` from terminating your application, set the signal handler for `SIGPIPE` to `SIG_IGN`.
    /// > Once ignored, the write operation simply fails with an `EPIPE` error (errno 32) instead of killing the process,
    /// > allowing your networking and streaming code to handle the disconnection gracefully with retries or user alerts."*
    ///
    /// This method is idempotent and safe to call early during application launch.
    public static func ignoreSigpipe() {
        #if canImport(Darwin)
        Darwin.signal(SIGPIPE, SIG_IGN)
        #elseif canImport(Glibc)
        Glibc.signal(SIGPIPE, SIG_IGN)
        #endif
    }
    
    /// Starts intercepting standard output and monitoring for crashes.
    ///
    /// - Parameter interceptCrashes: If `true`, sets up handlers for uncaught exceptions and fatal signals.
    public func startIntercepting(interceptCrashes: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        
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
        
        Task.detached(priority: .utility) { [weak self] in
            self?.readFromPipe(pipeReadEnd: pipeReadEnd, originalStdout: originalStdoutCopy)
        }
        
        // Setup crash handlers
        if interceptCrashes {
            setupCrashHandlers()
        }
    }
    
    /// Stops intercepting standard output and restores the original stdout.
    public func stopIntercepting() {
        lock.lock()
        defer { lock.unlock() }
        
        guard isIntercepting else { return }
        
        // Restore original stdout
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        close(pipe[0])
        originalStdout = -1
        pipe = [-1, -1]
        
        isIntercepting = false
    }
    
    /// Returns all captured output strings.
    ///
    /// This method is synchronized and safe to call concurrently from any thread.
    /// - Returns: An array of strings captured from stdout.
    public func getCapturedOutput() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedOutput
    }
    
    /// Returns the crash info if a crash has been detected in the current session.
    ///
    /// This is typically populated just before the app terminates.
    /// - Returns: `CrashInfo` if a crash occurred, otherwise `nil`.
    public func getCrashInfo() -> CrashInfo? {
        lock.lock()
        defer { lock.unlock() }
        return crashInfo
    }
    
    /// Clears all captured output and crash info.
    public func clearCapturedOutput() {
        lock.lock()
        defer { lock.unlock() }
        capturedOutput.removeAll()
        crashInfo = nil
    }
    
    /// Recovers crash info from a tombstone file if one exists.
    internal func recoverFromTombstone() {
        guard FileManager.default.fileExists(atPath: tombstoneURL.path) else { return }
        
        do {
            let content = try String(contentsOf: tombstoneURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")
            
            var signalName = "Unknown"
            var timestamp = Date()
            var callStack: [String] = []
            var isReadingStack = false
            
            for line in lines {
                if line.hasPrefix("STACK:") {
                    isReadingStack = true
                    continue
                }
                
                if line.hasPrefix("SIGNAL:") || line.hasPrefix("TIME:") || line.hasPrefix("APP:") || line.hasPrefix("BUILD:") {
                    isReadingStack = false
                }
                
                if line.hasPrefix("SIGNAL:"), let val = line.split(separator: ":").last {
                    signalName = String(val).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("TIME:"), let val = line.split(separator: ":").last, let ts = Double(val.trimmingCharacters(in: .whitespaces)) {
                    if ts > 0 {
                        timestamp = Date(timeIntervalSince1970: ts)
                    }
                } else if isReadingStack {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        callStack.append(trimmed)
                    }
                }
            }
            
            if callStack.isEmpty {
                callStack = ["Address recovery not implemented for tombstone"]
            }
            
            let crash = CrashInfo(
                timestamp: timestamp,
                reason: "Signal received (Recovered from tombstone)",
                callStack: callStack,
                signalInfo: signalName,
                appVersion: Self._appVersion,
                osVersion: Self._osVersion
            )
            
            // Save the formal crash report
            saveCrashInfo(crash)
            
            // Cleanup tombstone
            try? FileManager.default.removeItem(at: tombstoneURL)
            print("✅ Recovered crash from tombstone: \(signalName)")
            
        } catch {
            print("❌ Failed to recover from tombstone: \(error)")
        }
    }
    
    // MARK: - Signal Safe Storage
    nonisolated(unsafe) private static var tombstonePathPointer: UnsafeMutablePointer<CChar>?
    
    // MARK: - Private Methods
    
    private func readFromPipe(pipeReadEnd: Int32, originalStdout: Int32) {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        while true {
            lock.lock()
            let shouldContinue = isIntercepting
            lock.unlock()
            
            guard shouldContinue else { break }
            
            let bytesRead = read(pipeReadEnd, &buffer, bufferSize)
            
            guard bytesRead > 0 else { break }
            
            // Write to original stdout (so it still prints)
            _ = write(originalStdout, buffer, bytesRead)
            
            // Capture the output
            if let output = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                lock.lock()
                capturedOutput.append(output)
                if capturedOutput.count > maxLogCapacity {
                    capturedOutput.removeFirst(capturedOutput.count - maxLogCapacity)
                }
                lock.unlock()
            }
        }
    }
    
    // MARK: - Crash Handling
    
    private func setupCrashHandlers() {
        // NSException handler (for Objective-C exceptions)
        NSSetUncaughtExceptionHandler { exception in
            let crash = CrashInfo(
                timestamp: Date(),
                reason: exception.reason ?? "Unknown exception",
                callStack: exception.callStackSymbols,
                signalInfo: nil,
                appVersion: Wappn._appVersion,
                osVersion: Wappn._osVersion
            )
            Wappn.shared.handleCrash(crash)
        }
        
        // Prepare pre-allocated tombstone path for signal handler
        if let existing = Wappn.tombstonePathPointer {
            free(existing)
            Wappn.tombstonePathPointer = nil
        }
        Wappn.tombstonePathPointer = strdup(tombstoneURL.path)
        
        // Signal handlers for fatal signals.
        // Ignore SIGPIPE so broken network pipes surface as EPIPE error returns rather than crashing the process.
        Self.ignoreSigpipe()
        let signals: [Int32] = [SIGTRAP, SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGXCPU, SIGXFSZ, SIGSYS]
        
        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = { sig in
            Wappn.handleSignal(sig)
        }
        sa.sa_flags = SA_NODEFER | SA_RESETHAND
        sigemptyset(&sa.sa_mask)
        
        for sig in signals {
            sigaction(sig, &sa, nil)
        }
    }
    
    /// Low-level signal handler.
    ///
    /// ### Async-Signal Safety Trade-off:
    /// POSIX strictly defines a small set of async-signal-safe functions (e.g. `open`, `write`, `fsync`, `close`).
    /// Functions like `backtrace_symbols()` or `printf` allocate heap memory via `malloc` and acquire runtime/dyld locks,
    /// risking deadlock if the signal occurred while a thread was inside a critical section.
    ///
    /// To maximize diagnostics without sacrificing reliability:
    /// 1. We allocate the frame pointer buffer entirely on the stack using `withUnsafeTemporaryAllocation` (no `malloc`).
    /// 2. We deliberately avoid `backtrace_symbols()` and format pointer hex addresses directly to the file descriptor
    ///    using our stack-based `safeWritePointer` (zero heap allocations, no locks).
    /// 3. While Darwin's `backtrace()` uses `libunwind` which may theoretically access read locks, this is an intentional
    ///    diagnostic trade-off standard in Apple crash reporters (e.g., KSCrash, PLCrashReporter) to capture backtraces
    ///    without crashing or deadlocking in symbolication.
    private static func handleSignal(_ sig: Int32) {
        if let path = tombstonePathPointer {
            // Restrict tombstone creation permissions to 0o600 (owner read/write only)
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            if fd >= 0 {
                safeWrite(fd, "SIGNAL:")
                
                // Write signal name safely using static string literals
                switch sig {
                case SIGTRAP: safeWrite(fd, "SIGTRAP")
                case SIGABRT: safeWrite(fd, "SIGABRT")
                case SIGILL: safeWrite(fd, "SIGILL")
                case SIGSEGV: safeWrite(fd, "SIGSEGV")
                case SIGFPE: safeWrite(fd, "SIGFPE")
                case SIGBUS: safeWrite(fd, "SIGBUS")
                case SIGPIPE: safeWrite(fd, "SIGPIPE")
                case SIGXCPU: safeWrite(fd, "SIGXCPU")
                case SIGXFSZ: safeWrite(fd, "SIGXFSZ")
                case SIGSYS: safeWrite(fd, "SIGSYS")
                default: safeWrite(fd, "UNKNOWN")
                }
                
                safeWrite(fd, "\nTIME:0\n")
                
                // Write call stack backtrace to tombstone file descriptor using async-signal-safe formatting
                safeWrite(fd, "STACK:\n")
                withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 128) { buffer in
                    buffer.initialize(repeating: nil)
                    if let baseAddress = buffer.baseAddress {
                        let frameCount = backtrace(baseAddress, 128)
                        for index in 0..<Int(frameCount) {
                            if let ptr = buffer[index] {
                                safeWritePointer(fd, ptr)
                            }
                        }
                    }
                }
                
                // Flush and close
                fsync(fd)
                close(fd)
            }
        }
        
        // CRITICAL: Re-raise the signal to terminate the app.
        // We reset to default first to avoid infinite recursion.
        Darwin.signal(sig, SIG_DFL)
        Darwin.raise(sig)
    }

    /// Async-signal-safe write using static string literals in read-only memory.
    private static func safeWrite(_ fd: Int32, _ string: StaticString) {
        string.withUTF8Buffer { buffer in
            if let baseAddress = buffer.baseAddress, buffer.count > 0 {
                _ = write(fd, baseAddress, buffer.count)
            }
        }
    }

    /// Async-signal-safe write of a pointer address in hex format ("0x..." + "\n").
    /// Operates entirely on stack memory without dynamic allocation or runtime locks.
    @inline(__always)
    private static func safeWritePointer(_ fd: Int32, _ pointer: UnsafeMutableRawPointer) {
        var value = UInt(bitPattern: pointer)
        // Buffer layout: up to 16 hex digits + "0x" (2) + "\n" (1) = 19 bytes max
        var buffer: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
        let hexChars: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "3"),
            UInt8(ascii: "4"), UInt8(ascii: "5"), UInt8(ascii: "6"), UInt8(ascii: "7"),
            UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b"),
            UInt8(ascii: "c"), UInt8(ascii: "d"), UInt8(ascii: "e"), UInt8(ascii: "f")
        )

        withUnsafeMutableBytes(of: &buffer) { rawBuf in
            withUnsafeBytes(of: hexChars) { hexTable in
                var pos = 22 // write backwards from index 22
                rawBuf[23] = UInt8(ascii: "\n")
                if value == 0 {
                    rawBuf[pos] = UInt8(ascii: "0")
                    pos -= 1
                } else {
                    while value > 0 && pos >= 2 {
                        let digit = Int(value & 0xF)
                        rawBuf[pos] = hexTable[digit]
                        value >>= 4
                        pos -= 1
                    }
                }
                rawBuf[pos] = UInt8(ascii: "x")
                rawBuf[pos - 1] = UInt8(ascii: "0")
                
                let start = pos - 1
                let length = 24 - start
                if let base = rawBuf.baseAddress {
                    _ = write(fd, base.advanced(by: start), length)
                }
            }
        }
    }
    
    private func handleCrash(_ crash: CrashInfo) {
        // CRITICAL: Save crash info FIRST - this is the most important operation
        saveCrashInfo(crash)
        
        // Store crash info synchronously (no async!)
        lock.lock()
        crashInfo = crash
        // Log crash to captured output
        capturedOutput.append("\n" + crash.description + "\n")
        let callback = onCrash
        lock.unlock()
        
        // Call user callback synchronously - this is the last chance!
        callback?(crash)
        
        // Also write to original stdout
        if originalStdout >= 0 {
            let crashDesc = crash.description
            _ = crashDesc.withCString { ptr in
                write(originalStdout, ptr, strlen(ptr))
            }
        }
        print("⚠️ Wappn detected a crash: \(crash.reason)")
        
        // Force flush to disk AFTER writing everything
        fflush(stdout)
        fflush(stderr)
        sync() // Force all pending disk writes
    }
    
    internal func saveCrashInfo(_ crash: CrashInfo) {
        // CRITICAL: Use most reliable write method in crash scenario
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        guard let data = try? encoder.encode(crash) else {
            print("❌ Failed to encode crash info")
            return
        }
        
        writeCrashData(data)
    }
    
    private func writeCrashData(_ data: Data) {
        // Method 1: Try atomic write with fsync
        do {
            try data.write(to: crashFileURL, options: [.atomic])
            
            // CRITICAL: Open file in READ-WRITE mode for fsync (not O_RDONLY!)
            let fileDescriptor = open(crashFileURL.path, O_RDWR)
            if fileDescriptor >= 0 {
                fsync(fileDescriptor) // Force sync to physical disk
                close(fileDescriptor)
            }
            print("✅ Crash info saved to: \(crashFileURL.path)")
            return
        } catch {
            print("⚠️ Atomic write failed, trying low-level write: \(error)")
        }
        
        // Method 2: Fallback to direct file descriptor write (more reliable in crash scenarios)
        let fileDescriptor = open(crashFileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fileDescriptor >= 0 else {
            print("❌ Failed to open file descriptor")
            return
        }
        
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress, bytes.count > 0 else {
                return
            }
            _ = write(fileDescriptor, baseAddress, bytes.count)
        }
        fsync(fileDescriptor) // Force to disk
        close(fileDescriptor)
        print("✅ Crash info saved via low-level write: \(crashFileURL.path)")
    }
    
    /// Returns a descriptive name for a standard POSIX fatal signal.
    ///
    /// - Parameter signal: The POSIX signal integer (e.g., `SIGSEGV`, `SIGTRAP`).
    /// - Returns: A descriptive string representation of the signal.
    public static func signalName(for signal: Int32) -> String {
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
/// Formats a timestamp with microsecond precision (`HH:mm:ss.SSSSSS`).
/// - Parameter date: An optional `Date` to format. If `nil`, current time with microsecond precision is used.
/// - Returns: A formatted string representing time with microseconds.
public func formatTimestampWithMicroseconds(_ date: Date? = nil) -> String {
    var tv = timeval()
    if let date {
        let timeInterval = date.timeIntervalSince1970
        tv.tv_sec = time_t(timeInterval)
        let fractional = timeInterval - Double(tv.tv_sec)
        var usec = Int(round(fractional * 1_000_000))
        if usec >= 1_000_000 {
            tv.tv_sec += 1
            usec = 0
        }
        tv.tv_usec = suseconds_t(max(0, usec))
    } else {
        gettimeofday(&tv, nil)
    }
    var tmVal = tm()
    localtime_r(&tv.tv_sec, &tmVal)
    var buffer = [CChar](repeating: 0, count: 32)
    strftime(&buffer, buffer.count, "%H:%M:%S", &tmVal)
    let timeStr = buffer.withUnsafeBufferPointer { ptr in
        ptr.baseAddress.map { String(cString: $0) } ?? ""
    }
    let microseconds = String(format: "%06d", tv.tv_usec)
    return "\(timeStr).\(microseconds)"
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
    logItems(level, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
    #endif
}

#if DEBUG
func logItems(_ level: LogLevel,
              _ items: [Any],
              separator: String,
              terminator: String,
              file: String,
              line: Int,
              function: String) {
    let fileName = (file as NSString).lastPathComponent
    let output = items.map { "\($0)" }.joined(separator: separator)
    let timestamp = formatTimestampWithMicroseconds()
    let logMessage = "[\(timestamp)] [\(level.rawValue)] [\(fileName):\(line) \(function)] - \(output)"
    print(logMessage, terminator: terminator)
}
#endif

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
    logItems(.debug, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
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
    logItems(.info, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
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
    logItems(.warning, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
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
    logItems(.error, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
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
    logItems(.verbose, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
    #endif
}

