import Foundation
import Darwin

/// The helper once filled Swift's cooperative pool with waits that never returned,
/// so every later await, including the check that yields the library to the app,
/// stalled for 21 hours while it kept the writer lease. This watchdog runs on GCD:
/// when Swift concurrency or the main actor stops making progress, the helper exits
/// so flock releases the lease and launchd starts a fresh one.
final class HelperWatchdog:@unchecked Sendable {
    struct Timing:Sendable {
        var beat:Duration,check:TimeInterval,leaseStall:TimeInterval,idleStall:TimeInterval
        // A pass holds an activity assertion; idle beats may be stretched by App Nap.
        static let live=Timing(beat:.seconds(5),check:10,leaseStall:120,idleStall:600)
    }
    static let exitCode=EX_TEMPFAIL
    private let lock=NSLock()
    private var holdsLease=false
    private var lastBeat=DispatchTime.now().uptimeNanoseconds
    private var heartbeat:Task<Void,Never>?
    private var timer:DispatchSourceTimer?
    var leaseHeld:Bool {
        get {lock.withLock{holdsLease}}
        set {lock.withLock{holdsLease=newValue}}
    }

    func start(timing:Timing,onStall:@escaping @Sendable (_ stalledSeconds:TimeInterval)->Void) {
        lock.withLock{lastBeat=DispatchTime.now().uptimeNanoseconds}
        // Utility like the helper's work: a higher priority could still find a thread
        // while every utility thread is blocked.
        heartbeat=Task.detached(priority:.utility) {[self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:timing.beat)
                await MainActor.run {lock.withLock{lastBeat=DispatchTime.now().uptimeNanoseconds}}
            }
        }
        let timer=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"Emblem.HelperWatchdog",qos:.utility))
        timer.schedule(deadline:.now()+timing.check,repeating:timing.check)
        timer.setEventHandler {[self] in
            let (beat,lease)=lock.withLock{(lastBeat,holdsLease)}
            // Uptime excludes system sleep, so waking is never mistaken for a stall.
            let stalled=Double(DispatchTime.now().uptimeNanoseconds-beat)/1_000_000_000
            if stalled >= (lease ? timing.leaseStall : timing.idleStall) {onStall(stalled)}
        }
        self.timer=timer;timer.resume()
    }

    static func recordRestart(root:URL,stalledSeconds:TimeInterval) {
        let status:[String:Any]=["state":"watchdog-restart","pid":getpid(),"timestamp":Date().timeIntervalSinceReferenceDate,
                                 "attention":"The background helper stopped responding for \(Int(stalledSeconds)) seconds and restarted."]
        let url=root.appendingPathComponent("background-status.json")
        if let data=try? JSONSerialization.data(withJSONObject:status,options:.sortedKeys) {
            try? data.write(to:url,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
    }

    /// Isolated fixture: stalls Swift concurrency or the main thread while holding a
    /// fixture lease, or stays healthy, and never touches the live library.
    static func fixture(arguments:[String])->Int32 {
        guard let dir=arguments.firstIndex(of:"--data-dir"),dir+1<arguments.count,
              let modeIndex=arguments.firstIndex(of:"--mode"),modeIndex+1<arguments.count else{return 64}
        let root=URL(fileURLWithPath:arguments[dir+1]).standardizedFileURL,mode=arguments[modeIndex+1]
        guard root != LibraryLease.liveRoot.standardizedFileURL,["healthy","pool","main","idle-pool"].contains(mode) else{return 64}
        let lease:LibraryLease?
        do {lease=mode=="idle-pool" ? nil : try LibraryLease.acquire(root:root)} catch {return 1}
        guard mode=="idle-pool" || lease != nil else{return 1}
        let watchdog=HelperWatchdog();watchdog.leaseHeld=lease != nil
        watchdog.start(timing:.init(beat:.milliseconds(100),check:0.1,leaseStall:2,idleStall:5)) {stalled in
            recordRestart(root:root,stalledSeconds:stalled)
            _exit(exitCode)
        }
        let never=DispatchSemaphore(value:0)
        switch mode {
        case "pool","idle-pool":
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount+2 {Task.detached(priority:.utility) {block(never)}}
        case "main":
            DispatchQueue.main.async {block(never)}
        default:
            DispatchQueue.main.asyncAfter(deadline:.now()+4) {print("WATCHDOG_HEALTHY=PASS");fflush(stdout);exit(0)}
        }
        withExtendedLifetime(lease) {RunLoop.main.run()}
        return 1
    }
    private static func block(_ semaphore:DispatchSemaphore) {semaphore.wait()}
}
