# Wappn

**Wappn** is a lightweight Swift package for iOS that provides crash reporting and log interception capabilities. It allows you to capture standard output (stdout), detect crashes from previous sessions, and handle them gracefully.

## Features

- **Crash Detection**: Automatically detects if the app crashed in the previous session.
- **Crash Reporting**: Captures detailed crash information including stack traces, signal info, and timestamps.
- **Log Interception**: Redirects and captures `stdout` and `print` statements, making them available for debugging or reporting.
- **Custom Logging**: Provides a set of logging functions (`logd`, `logi`, `logw`, `loge`) with emoji indicators and timestamps.
- **Thread Safe**: Designed with concurrency in mind using internal dispatch queues.

## Installation

### Swift Package Manager

Add `Wappn` to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/acme/Wappn.git", from: "1.0.0")
]
```

## Usage

### 1. Setup in AppDelegate

Initialize `Wappn` in your `application(_:didFinishLaunchingWithOptions:)` method to handle previous crashes and start interception.

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    
    // 1. Check for previous crash
    if Wappn.shared.didCrashLastTime() {
        if let crashInfo = Wappn.shared.getLastCrashInfo() {
            print("App crashed last time: \(crashInfo.reason)")
            // Handle crash report (e.g., upload to server)
        }
        Wappn.shared.clearCrashMarker()
    }
    
    // 2. Start intercepting logs and crashes
    Wappn.shared.startIntercepting()
    
    // 3. Optional: Handle crashes in real-time
    Wappn.shared.onCrash = { crashInfo in
        // Save critical data before termination
    }
    
    return true
}
```

### 2. Logging

Use the provided global logging functions to capture logs with different levels:

```swift
logd("Debug message")      // 🔍 DEBUG
logi("Info message")       // ℹ️ INFO
logw("Warning message")    // ⚠️ WARNING
loge("Error message")      // ❌ ERROR
```

### 3. Retrieving Logs

You can retrieve all captured logs at any time:

```swift
let logs = Wappn.shared.getCapturedOutput()
print("Total logs captured: \(logs.count)")
```
