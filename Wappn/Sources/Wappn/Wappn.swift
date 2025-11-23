import Foundation

// MARK: - Crash Info
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
    private let crashMarkerKey = "com.wappn.didCrashLastTime"
    private let lastCrashKey = "com.wappn.lastCrashInfo"
    
    // Crash handler callback
    public var onCrash: (@Sendable (CrashInfo) -> Void)?
    
    private init() {
        // Setup crash file path
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        crashFileURL = documents.appendingPathComponent("last_crash.json")
        
        // Mark app as running (if it crashes, this won't be cleared)
        UserDefaults.standard.set(true, forKey: crashMarkerKey)
        UserDefaults.standard.synchronize()
    }
    
    // MARK: - Public Methods
    
    /// Check if app crashed in previous session
    public func didCrashLastTime() -> Bool {
        return UserDefaults.standard.bool(forKey: crashMarkerKey)
    }
    
    /// Get crash info from previous session
    public func getLastCrashInfo() -> CrashInfo? {
        // Try to load from file first (most detailed)
        if let data = try? Data(contentsOf: crashFileURL),
           let crash = try? JSONDecoder().decode(CrashInfo.self, from: data) {
            return crash
        }
        
        // Fallback to UserDefaults
        if let data = UserDefaults.standard.data(forKey: lastCrashKey),
           let crash = try? JSONDecoder().decode(CrashInfo.self, from: data) {
            return crash
        }
        
        return nil
    }
    
    /// Clear crash marker - call after handling previous crash
    public func clearCrashMarker() {
        UserDefaults.standard.set(false, forKey: crashMarkerKey)
        UserDefaults.standard.removeObject(forKey: lastCrashKey)
        try? FileManager.default.removeItem(at: crashFileURL)
        UserDefaults.standard.synchronize()
    }
    
    /// Mark app as successfully launched
    public func markLaunchSuccess() {
        clearCrashMarker()
    }
    
    public func startIntercepting(interceptCrashes: Bool = true) {
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
    
    public func stopIntercepting() {
        guard isIntercepting else { return }
        
        // Restore original stdout
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        close(pipe[0])
        
        isIntercepting = false
    }
    
    public func getCapturedOutput() -> [String] {
        return queue.sync {
            return capturedOutput
        }
    }
    
    public func getCrashInfo() -> CrashInfo? {
        return queue.sync {
            return crashInfo
        }
    }
    
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
        
        while isIntercepting {
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
        // NSException handler
        NSSetUncaughtExceptionHandler { exception in
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
        let signals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE]
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
        // Save crash info synchronously (we're about to crash!)
        saveCrashInfo(crash)
        
        queue.async(flags: .barrier) { [weak self] in
            self?.crashInfo = crash
            
            // Log crash to captured output
            self?.capturedOutput.append("\n" + crash.description + "\n")
            
            // Call user callback
            self?.onCrash?(crash)
        }
        
        // Also write to original stdout
        if originalStdout >= 0 {
            let crashDesc = crash.description
            _ = crashDesc.withCString { ptr in
                write(originalStdout, ptr, strlen(ptr))
            }
        }
    }
    
    private func saveCrashInfo(_ crash: CrashInfo) {
        // Save to file
        if let data = try? JSONEncoder().encode(crash) {
            try? data.write(to: crashFileURL, options: .atomic)
            
            // Also save to UserDefaults as backup
            UserDefaults.standard.set(data, forKey: lastCrashKey)
            UserDefaults.standard.synchronize()
        }
    }
    
    private func signalName(for signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT (Abort)"
        case SIGILL: return "SIGILL (Illegal Instruction)"
        case SIGSEGV: return "SIGSEGV (Segmentation Fault)"
        case SIGFPE: return "SIGFPE (Floating Point Exception)"
        case SIGBUS: return "SIGBUS (Bus Error)"
        case SIGPIPE: return "SIGPIPE (Broken Pipe)"
        default: return "Signal \(signal)"
        }
    }
}

// MARK: - Enhanced Logger with Interception

public enum LogLevel: String {
    case debug = "🔍 DEBUG"
    case info = "ℹ️ INFO"
    case warning = "⚠️ WARNING"
    case error = "❌ ERROR"
    case verbose = "💬 VERBOSE"
}

@inlinable
@inline(__always)
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

@inlinable
@inline(__always)
public func logd(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    log(.debug, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
    #endif
}

@inlinable
@inline(__always)
public func logi(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    log(.info, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
    #endif
}

@inlinable
@inline(__always)
public func logw(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    log(.warning, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
    #endif
}

@inlinable
@inline(__always)
public func loge(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    log(.error, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
    #endif
}

@inlinable
@inline(__always)
public func logv(_ items: Any...,
                 separator: String = " ",
                 terminator: String = "\n",
                 file: String = #file,
                 line: Int = #line,
                 function: String = #function) {
    #if DEBUG
    log(.verbose, items, separator: separator, terminator: terminator, file: file, line: line, function: function)
    #endif
}

// MARK: - Usage Example
/*

// === AT APP LAUNCH (AppDelegate/SceneDelegate) ===

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    
    // Check for previous crash BEFORE starting interception
    if Wappn.shared.didCrashLastTime() {
        print("⚠️ App crashed in previous session!")
        
        // Get detailed crash info
        if let crashInfo = Wappn.shared.getLastCrashInfo() {
            print(crashInfo.description)
            
            // Handle crash: upload to server, show alert, etc.
            uploadCrashReport(crashInfo)
            
            // Or show alert to user
            showCrashAlert(crashInfo)
        }
        
        // Clear crash marker after handling
        Wappn.shared.clearCrashMarker()
    }
    
    // Start intercepting for this session
    Wappn.shared.startIntercepting(interceptCrashes: true)
    
    // Optional: Set crash callback for current session
    Wappn.shared.onCrash = { crashInfo in
        print("App is crashing! Saving report...")
        // Last chance to save data before crash
    }
    
    // Mark successful launch (optional, after your app is stable)
    // Call this after critical initialization succeeds
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        Wappn.shared.markLaunchSuccess()
    }
    
    return true
}

// === DURING APP RUNTIME ===

// Normal logging - all captured
logd("Debug message")
logi("App started successfully")
print("Regular output")

// Get all captured output
let allOutput = Wappn.shared.getCapturedOutput()

// === EXAMPLE: Show crash alert ===

func showCrashAlert(_ crashInfo: CrashInfo) {
    let alert = UIAlertController(
        title: "Previous Crash Detected",
        message: "The app crashed last time. Would you like to send a crash report?",
        preferredStyle: .alert
    )
    
    alert.addAction(UIAlertAction(title: "Send Report", style: .default) { _ in
        uploadCrashReport(crashInfo)
    })
    
    alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel))
    
    // Present alert
    // window?.rootViewController?.present(alert, animated: true)
}

func uploadCrashReport(_ crashInfo: CrashInfo) {
    let report = crashInfo.description
    // Upload to your server, Firebase Crashlytics, etc.
    print("Uploading crash report...")
}

*/
