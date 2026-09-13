import Foundation
import Darwin

/// The GUI and launch agent share a library, never a writer. flock also releases
/// after a crash, so a stale PID file cannot permanently lock out either process.
final class LibraryLease {
    static let requestName="foreground-request.json"
    let root:URL
    private let fd:Int32
    private init(root:URL,fd:Int32){self.root=root;self.fd=fd}
    deinit {flock(fd,LOCK_UN);close(fd)}
    static var liveRoot:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Emblem",isDirectory:true)}
    static func acquire(root:URL)throws->LibraryLease? {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=open(root.appendingPathComponent("library-writer.lock").path,O_RDWR|O_CREAT|O_CLOEXEC,0o600)
        guard fd>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else {
            let error=errno;close(fd)
            if error==EWOULDBLOCK {return nil}
            throw POSIXError(POSIXErrorCode(rawValue:error) ?? .EIO)
        }
        return LibraryLease(root:root,fd:fd)
    }
    static func requestForeground(root:URL)throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try JSONSerialization.data(withJSONObject:["pid":getpid()])
        let url=root.appendingPathComponent(requestName)
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func foregroundRequested(root:URL)->Bool {
        guard let data=try? Data(contentsOf:root.appendingPathComponent(requestName)),
              let value=try? JSONSerialization.jsonObject(with:data) as? [String:Int],let pid=value["pid"],pid>0 else {return false}
        return kill(pid_t(pid),0)==0 || errno==EPERM
    }
    static func clearOwnRequest(root:URL) {
        let url=root.appendingPathComponent(requestName)
        guard let data=try? Data(contentsOf:url),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Int],value["pid"]==Int(getpid()) else {return}
        try? FileManager.default.removeItem(at:url)
    }
    static func fixture(arguments:[String])->Int32 {
        guard let index=arguments.firstIndex(of:"--data-dir"),index+1<arguments.count else{return 64}
        let root=URL(fileURLWithPath:arguments[index+1]).standardizedFileURL
        guard root != liveRoot.standardizedFileURL else{return 64}
        do {
            if arguments.contains("--request") {
                try requestForeground(root:root);defer{clearOwnRequest(root:root)}
                for _ in 0..<100 {
                    if let lease=try acquire(root:root) {withExtendedLifetime(lease){print("LEASE_TAKEOVER=PASS")};return 0}
                    Thread.sleep(forTimeInterval:0.05)
                }
                return 75
            }
            guard let lease=try acquire(root:root) else {print("LEASE_BUSY=PASS");return 75}
            defer {withExtendedLifetime(lease){}}
            print("LEASE_ACQUIRED=PASS");fflush(stdout)
            if arguments.contains("--hold") {
                for _ in 0..<200 where !foregroundRequested(root:root) {Thread.sleep(forTimeInterval:0.05)}
                print("LEASE_YIELDED=PASS")
            }
            return 0
        } catch {print(error.localizedDescription);return 1}
    }
}
