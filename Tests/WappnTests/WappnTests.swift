import Foundation
import Testing
@testable import Wappn

@Suite("Wappn Crash Reporter & Log Interception Tests", .serialized)
struct WappnTests {
    
    @Test("CrashInfo encoding and decoding preserves all fields")
    func crashInfoEncodingDecoding() throws {
        let timestamp = Date(timeIntervalSince1970: 1700000000)
        let info = CrashInfo(
            timestamp: timestamp,
            reason: "Fatal runtime assertion failure",
            callStack: ["0x100000001 start", "0x100000002 main"],
            signalInfo: "SIGTRAP",
            appVersion: "1.0.0",
            osVersion: "macOS 15.0"
        )
        
        let description = info.description
        #expect(description.contains("=== CRASH REPORT ==="))
        #expect(description.contains("SIGTRAP"))
        #expect(description.contains("Fatal runtime assertion failure"))
        #expect(description.contains("1.0.0"))
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(info)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CrashInfo.self, from: data)
        
        #expect(decoded.reason == info.reason)
        #expect(decoded.signalInfo == info.signalInfo)
        #expect(decoded.appVersion == info.appVersion)
        #expect(decoded.osVersion == info.osVersion)
        #expect(decoded.callStack == info.callStack)
    }
    
    @Test("Signal name mapping outputs correct descriptions")
    func signalNameMapping() {
        #expect(Wappn.signalName(for: SIGTRAP).contains("SIGTRAP"))
        #expect(Wappn.signalName(for: SIGABRT).contains("SIGABRT"))
        #expect(Wappn.signalName(for: SIGILL).contains("SIGILL"))
        #expect(Wappn.signalName(for: SIGSEGV).contains("SIGSEGV"))
        #expect(Wappn.signalName(for: SIGFPE).contains("SIGFPE"))
        #expect(Wappn.signalName(for: SIGBUS).contains("SIGBUS"))
        #expect(Wappn.signalName(for: SIGPIPE).contains("SIGPIPE"))
        #expect(Wappn.signalName(for: SIGXCPU).contains("SIGXCPU"))
        #expect(Wappn.signalName(for: SIGXFSZ).contains("SIGXFSZ"))
        #expect(Wappn.signalName(for: SIGSYS).contains("SIGSYS"))
        #expect(Wappn.signalName(for: 999) == "Signal 999")
    }
    
    @Test("Crash marker lifecycle: save, detect, read, clear")
    func crashMarkerLifecycle() throws {
        let wappn = Wappn.shared
        wappn.clearCrashMarker()
        #expect(!wappn.didCrashLastTime())
        #expect(wappn.getLastCrashInfo() == nil)
        
        let crash = CrashInfo(
            timestamp: Date(),
            reason: "Simulated out of memory exception",
            callStack: ["0xdeadbeef frame1"],
            signalInfo: nil,
            appVersion: "2.1.0",
            osVersion: "iOS 17.5"
        )
        
        wappn.saveCrashInfo(crash)
        
        #expect(wappn.didCrashLastTime())
        let loaded = wappn.getLastCrashInfo()
        #expect(loaded != nil)
        #expect(loaded?.reason == "Simulated out of memory exception")
        #expect(loaded?.appVersion == "2.1.0")
        
        wappn.markLaunchSuccess()
        #expect(!wappn.didCrashLastTime())
        #expect(wappn.getLastCrashInfo() == nil)
    }
    
    @Test("Tombstone recovery restores signal crash and cleans up file")
    func tombstoneRecovery() throws {
        let wappn = Wappn.shared
        wappn.clearCrashMarker()
        
        // Write mock tombstone
        let tombstoneContent = "SIGNAL:SIGSEGV\nTIME:1710000000\n"
        try tombstoneContent.write(to: wappn.tombstoneURL, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: wappn.tombstoneURL.path))
        
        // Trigger recovery
        wappn.recoverFromTombstone()
        
        // Tombstone should be removed
        #expect(!FileManager.default.fileExists(atPath: wappn.tombstoneURL.path))
        
        // Crash info should now be recorded
        #expect(wappn.didCrashLastTime())
        let recovered = wappn.getLastCrashInfo()
        #expect(recovered != nil)
        #expect(recovered?.signalInfo == "SIGSEGV")
        #expect(recovered?.reason.contains("Recovered from tombstone") == true)
        
        // Clean up
        wappn.clearCrashMarker()
    }
    
    @Test("Log capture and buffer management")
    func outputCaptureAndClearing() {
        let wappn = Wappn.shared
        wappn.clearCapturedOutput()
        #expect(wappn.getCapturedOutput().isEmpty)
        #expect(wappn.getCrashInfo() == nil)
        
        // Verify logger functions execute cleanly
        logd("Test debug message")
        logi("Test info message")
        logw("Test warning message")
        loge("Test error message")
        logv("Test verbose message")
        
        wappn.clearCapturedOutput()
        #expect(wappn.getCapturedOutput().isEmpty)
    }

    @Test("Microsecond timestamp formatting produces valid HH:mm:ss.SSSSSS format")
    func microsecondTimestampFormatting() {
        let timestamp = formatTimestampWithMicroseconds()
        let parts = timestamp.split(separator: ".")
        #expect(parts.count == 2)
        #expect(parts[1].count == 6)
        
        let timeParts = parts[0].split(separator: ":")
        #expect(timeParts.count == 3)
        
        let date = Date(timeIntervalSince1970: 1700000000.123456)
        let formatted = formatTimestampWithMicroseconds(date)
        let dateParts = formatted.split(separator: ".")
        #expect(dateParts.count == 2)
        #expect(dateParts[1] == "123456")
    }
}
