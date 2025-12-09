# Wappn

**Wappn** is a lightweight, thread-safe Swift package for iOS that provides comprehensive crash reporting and log interception capabilities. It captures both Swift runtime errors and Objective-C exceptions, making it ideal for mixed-language codebases.

## Features

- **🛡️ Comprehensive Crash Detection**: 
  - Swift runtime errors (via SIGTRAP signal)
  - Objective-C exceptions (via NSSetUncaughtExceptionHandler)
  - Fatal signals (SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE, SIGXCPU, SIGXFSZ, SIGSYS)
  
- **📊 Detailed Crash Reporting**: 
  - Full stack traces
  - Signal information
  - Timestamps
  - App version and OS version
  - Persistent crash data across app launches

- **📝 Log Interception**: 
  - Redirects and captures stdout
  - Captures all `print` statements
  - Thread-safe log collection

- **🎨 Custom Logging**: 
  - Emoji-prefixed log levels (`logd`, `logi`, `logw`, `loge`, `logv`)
  - Timestamps and file/line information
  - Debug-only compilation (zero overhead in release builds)

- **🔒 Thread Safe**: 
  - NSLock-based synchronization
  - Safe for concurrent access
  - Crash handlers work synchronously (no async/await overhead)

## Installation

### Swift Package Manager

Add `Wappn` to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/acme/Wappn.git", from: "1.0.0")
]
```

Or add it in Xcode:
1. File → Add Packages...
2. Enter the repository URL
3. Select version/branch

## Usage

### 1. Setup in App Launch

Initialize `Wappn` early in your app lifecycle to handle previous crashes and start monitoring.

**SwiftUI App:**
```swift
@main
struct MyApp: App {
    init() {
        setupWappn()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
    private func setupWappn() {
        // Check for previous crash
        if Wappn.shared.didCrashLastTime() {
            if let crashInfo = Wappn.shared.getLastCrashInfo() {
                print("⚠️ App crashed last time:")
                print(crashInfo.description)
                // Upload to crash reporting service, show alert, etc.
            }
            Wappn.shared.clearCrashMarker()
        }
        
        // Start crash monitoring
        Wappn.shared.startIntercepting(interceptCrashes: true)
        
        // Optional: Handle crashes in real-time
        Wappn.shared.onCrash = { crashInfo in
            // Last chance to save critical data
            // Keep this SHORT - app is about to terminate!
            print("💥 Crash detected: \(crashInfo.reason)")
        }
        
        // Mark successful launch
        Wappn.shared.markLaunchSuccess()
    }
}
```

**UIKit AppDelegate:**
```swift
func application(_ application: UIApplication, 
                didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    
    // Check for previous crash
    if Wappn.shared.didCrashLastTime() {
        if let crashInfo = Wappn.shared.getLastCrashInfo() {
            handlePreviousCrash(crashInfo)
        }
        Wappn.shared.clearCrashMarker()
    }
    
    // Start monitoring
    Wappn.shared.startIntercepting(interceptCrashes: true)
    
    Wappn.shared.onCrash = { crashInfo in
        // Save critical data before termination
    }
    
    return true
}
```

### 2. Logging

Use the provided global logging functions for debug-only logs with rich metadata:

```swift
logd("Debug message")           // 🔍 DEBUG
logi("Info message")            // ℹ️ INFO  
logw("Warning message")         // ⚠️ WARNING
loge("Error message")           // ❌ ERROR
logv("Verbose details")         // 💬 VERBOSE

// Logs include: timestamp, file, line, function name
// Output: [10:30:45] 🔍 DEBUG [MyView.swift:42] loadData() - Debug message
```

**Note**: All logging functions are compiled out in Release builds (zero overhead).

### 3. Retrieving Captured Logs

Access all captured output programmatically:

```swift
let logs = Wappn.shared.getCapturedOutput()
print("Total logs: \(logs.count)")

// Clear logs after processing
Wappn.shared.clearCapturedOutput()
```

### 4. Crash Information Structure

```swift
public struct CrashInfo: Codable {
    let timestamp: Date
    let reason: String
    let callStack: [String]
    let signalInfo: String?      // e.g., "SIGTRAP (Swift Runtime Error)"
    let appVersion: String
    let osVersion: String
}
```

### 5. Advanced Usage

#### Custom Crash Handling
```swift
Wappn.shared.onCrash = { crashInfo in
    // Upload to analytics service
    Analytics.recordCrash(crashInfo)
    
    // Save user data
    UserDefaults.standard.synchronize()
    
    // WARNING: Keep this fast and synchronous!
    // The app will terminate immediately after.
}
```

#### Accessing Crash Files
```swift
let crashFilePath = Wappn.shared.getCrashFilePath()
print("Crashes saved to: \(crashFilePath)")
```

#### Stopping Interception
```swift
// Stop capturing logs (rare - usually run throughout app lifecycle)
Wappn.shared.stopIntercepting()
```

## Signal Handling

Wappn intercepts the following fatal signals:

| Signal | Description | Typical Cause |
|--------|-------------|---------------|
| **SIGTRAP** | Swift Runtime Error | Force unwrap of nil (`!`), precondition failures, array bounds |
| **SIGABRT** | Abort | Assertions, `fatalError()`, Objective-C exceptions |
| **SIGILL** | Illegal Instruction | Corrupted code, wrong architecture |
| **SIGSEGV** | Segmentation Fault | Invalid memory access, dangling pointers |
| **SIGFPE** | Floating Point Exception | Division by zero, invalid math operations |
| **SIGBUS** | Bus Error | Misaligned memory access |
| **SIGPIPE** | Broken Pipe | Writing to closed socket/pipe |
| **SIGXCPU** | CPU Limit Exceeded | Process exceeded CPU time limit |
| **SIGXFSZ** | File Size Limit Exceeded | Writing beyond file size limits |
| **SIGSYS** | Bad System Call | Invalid syscall number |

## Architecture

- **Thread Safety**: Uses `NSLock` for synchronization (not actor-based, as crash handlers must be synchronous)
- **Crash Persistence**: Uses atomic writes + fsync for reliable crash data persistence
- **Dual Write Strategy**: Attempts atomic write first, falls back to low-level file descriptor write
- **Mixed Language Support**: Handles both Swift runtime errors and Objective-C exceptions

## Limitations

- **Debug Console**: Xcode's console may still show some output even when intercepted
- **Signal Safety**: Crash handlers execute in a constrained environment - avoid complex operations
- **iOS Only**: Currently designed for iOS (may work on macOS with modifications)
- **No Async Operations**: Crash handlers must be synchronous (can't use async/await)

## Best Practices

1. ✅ **Initialize Early**: Set up Wappn before other initializations
2. ✅ **Keep Crash Handlers Fast**: Minimize work in `onCrash` callback
3. ✅ **Upload Crash Reports**: Send crash data to your backend for analysis
4. ✅ **Clear Old Crashes**: Call `clearCrashMarker()` after handling
5. ❌ **Don't Use Async**: Crash handlers must be synchronous
6. ❌ **Don't Allocate Memory**: Minimize allocations in crash handlers
7. ❌ **Don't Use Locks**: Avoid complex synchronization in crash handlers

## Example Crash Detection Flow

```swift
// App launches
if Wappn.shared.didCrashLastTime() {
    // 1. Previous session crashed
    let crash = Wappn.shared.getLastCrashInfo()
    
    // 2. Upload to backend
    CrashReporter.upload(crash)
    
    // 3. Show recovery UI
    showCrashRecoveryScreen()
    
    // 4. Clean up
    Wappn.shared.clearCrashMarker()
}

// Start monitoring this session
Wappn.shared.startIntercepting(interceptCrashes: true)
Wappn.shared.markLaunchSuccess()
```

## Testing

To test crash detection:

```swift
// Swift runtime error (SIGTRAP)
let array = [1, 2, 3]
_ = array[10]  // Will trigger SIGTRAP

// Force unwrap crash
let optional: String? = nil
_ = optional!  // Will trigger SIGTRAP

// Fatal error
fatalError("Test crash")  // Will trigger SIGABRT

// Precondition failure  
preconditionFailure("Test")  // Will trigger SIGTRAP
```

## Requirements

- iOS 14.0+
- Swift 5.5+
- Xcode 13.0+

## License

[Your License Here]

## Contributing

Contributions are welcome! Please submit pull requests or open issues.

## Credits

Developed with ❤️ for robust iOS crash reporting.
