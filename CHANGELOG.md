# Wappn Changelog

## [Unreleased] - 2024-12-09

### Changed - Major Architecture Refactor

#### Converted from Actor to Thread-Safe Class
**Reasoning**: Actor model is inappropriate for crash handling:
- ❌ Actors require async/await, but crash handlers **MUST** be synchronous
- ❌ Signal handlers execute in constrained environment where async doesn't work  
- ❌ NSSetUncaughtExceptionHandler cannot use async operations
- ❌ Added unnecessary performance overhead
- ❌ Made API harder to use (required await everywhere)

**Solution**: Converted to thread-safe class using NSLock:
- ✅ All operations are synchronous (no await needed)
- ✅ Crash handlers work correctly in signal/exception context
- ✅ Better performance (no actor isolation overhead)
- ✅ Simpler, cleaner API
- ✅ Still 100% thread-safe via NSLock

### Added

#### Comprehensive Signal Handling
Added 3 new signal handlers for complete coverage:
- `SIGXCPU` - CPU time limit exceeded
- `SIGXFSZ` - File size limit exceeded  
- `SIGSYS` - Bad system call

**Complete signal list** (10 signals):
1. SIGTRAP - Swift runtime errors (force unwrap, preconditions)
2. SIGABRT - Abort signals (assertions, fatalError)
3. SIGILL - Illegal instruction
4. SIGSEGV - Segmentation fault
5. SIGFPE - Floating point exception
6. SIGBUS - Bus error
7. SIGPIPE - Broken pipe
8. SIGXCPU - CPU limit exceeded (NEW)
9. SIGXFSZ - File size limit exceeded (NEW)
10. SIGSYS - Bad system call (NEW)

#### Enhanced Documentation
- Added detailed signal descriptions in code comments
- Updated README with comprehensive usage guide
- Added signal reference table
- Included best practices and limitations
- Added testing examples

### Fixed

#### Thread Safety Improvements
- Added NSLock protection to all mutable state access
- Fixed race conditions in `readFromPipe()`
- Protected `capturedOutput` array modifications
- Synchronized `isIntercepting` flag access
- Made crash handler thread-safe with local callback copy

#### Code Quality
- Removed unused/duplicate methods (`writeAtomic` and `writeLowLevel` merged into `writeCrashData`)
- Simplified file writing logic with single method and fallback
- Removed unnecessary `self.` qualifiers
- Improved code organization and comments
- Removed all actor-related annotations (@MainActor)

### Technical Details

#### Before (Actor):
```swift
public final actor Wappn {
    public func startIntercepting() async { ... }  // Required await
    public func getCrashInfo() async -> CrashInfo? { ... }  // Required await
}

// Usage - awkward:
Task {
    await Wappn.shared.startIntercepting()
    let crash = await Wappn.shared.getCrashInfo()
}
```

#### After (Thread-Safe Class):
```swift
public final class Wappn {
    private let lock = NSLock()
    
    public func startIntercepting() { ... }  // Synchronous
    public func getCrashInfo() -> CrashInfo? { ... }  // Synchronous
}

// Usage - simple:
Wappn.shared.startIntercepting()
let crash = Wappn.shared.getCrashInfo()
```

### Breaking Changes

⚠️ **API is now synchronous** - Remove all `await` keywords when calling Wappn methods:

```swift
// Before:
await Wappn.shared.startIntercepting()
await Wappn.shared.clearCrashMarker()

// After:
Wappn.shared.startIntercepting()
Wappn.shared.clearCrashMarker()
```

This is actually an **improvement** as it simplifies usage and removes unnecessary async complexity.

### Performance Impact

- **Improved**: Removed actor isolation overhead
- **Improved**: Direct synchronous access (no context switching)
- **Improved**: Lighter weight locking (NSLock vs actor mailbox)
- **No change**: Crash handling performance (already critical path)

### Migration Guide

If you were using the actor version:

1. Remove all `await` keywords before Wappn calls
2. Remove `Task { }` wrappers around Wappn usage
3. Can now call from synchronous contexts directly
4. No need for `@MainActor` annotations

```swift
// Old (Actor version):
func setupCrashReporting() {
    Task {
        if await Wappn.shared.didCrashLastTime() {
            let crash = await Wappn.shared.getLastCrashInfo()
            // handle crash
        }
        await Wappn.shared.startIntercepting()
    }
}

// New (Thread-safe class):
func setupCrashReporting() {
    if Wappn.shared.didCrashLastTime() {
        let crash = Wappn.shared.getLastCrashInfo()
        // handle crash
    }
    Wappn.shared.startIntercepting()
}
```

### Testing Recommendations

Test crash detection with:

```swift
// Swift runtime errors (SIGTRAP)
let array = [1, 2, 3]
_ = array[10]  // Index out of bounds

let value: String? = nil
_ = value!  // Force unwrap nil

// Assertions (SIGABRT)
fatalError("Test crash")
preconditionFailure("Test precondition")

// Invalid memory (SIGSEGV) - careful!
// let ptr = UnsafeMutablePointer<Int>(bitPattern: 1)!
// _ = ptr.pointee  // Segfault
```

### References

- [Stack Overflow: NSSetUncaughtExceptionHandler vs Signal Handlers](https://stackoverflow.com/)
- [Apple Documentation: Signal Handling](https://developer.apple.com/documentation/os/signal_handling)
- SIGTRAP is essential for Swift runtime error detection

---

## Summary

This release converts Wappn from an inappropriate actor-based design to a proper thread-safe class, making it suitable for real-world crash handling. The API is simpler, faster, and actually works correctly in crash scenarios.
