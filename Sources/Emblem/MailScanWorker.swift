import AppKit
import Carbon
import Foundation
import Darwin
import PortraitCore

struct MailScriptRequest:Codable,Sendable {var handler:String;var arguments:[ScriptValue]}
struct MailScriptResponse:Codable,Sendable {var value:ScriptValue?;var error:String?;var mainThread:Bool}

/// NSAppleScript must not migrate between Swift cooperative executor threads.
/// A disposable same-bundle helper owns it on the main thread. Its hard deadline
/// and process lifetime also bound a non-cooperative Apple-event call.
actor MailScanScriptRunner {
    static let shared=MailScanScriptRunner()
    private let executable:URL?
    private let workerArguments:[String]
    init(executable:URL?=Bundle.main.executableURL,arguments:[String]=["--mail-scan-worker"]) {self.executable=executable;workerArguments=arguments}
    func call(_ handler:String,arguments:[ScriptValue])async throws->ScriptValue {
        try Task.checkCancellation()
        guard let executable else{throw PortraitError.message("The Mail scan executable is missing.")}
        let request=try JSONEncoder().encode(MailScriptRequest(handler:handler,arguments:arguments))
        let workerArguments=self.workerArguments
        let data=try await withDeadline(seconds:["scaninventory","scanroutedinventory"].contains(handler) ? 45 : 25) {
            try await MailScanChild.output(executable:executable,arguments:workerArguments,input:request)
        }
        let response=try JSONDecoder().decode(MailScriptResponse.self,from:data)
        guard response.mainThread,let value=response.value else {throw PortraitError.message(response.error ?? "Mail returned incomplete scan data.")}
        return value
    }
}

/// Never use Process.waitUntilExit() here. Foundation lists launched tasks by
/// unretained address per thread; on a reused Swift executor thread a recycled
/// address makes it wait for an exit notification queued on another thread's run
/// loop, so it never returns and permanently occupies a cooperative thread.
/// Exit arrives through the termination handler, and pipe I/O stays on GCD.
private enum MailScanChild {
    private final class Completion:@unchecked Sendable {
        private let lock=NSLock()
        private var exited=false,output:Result<Data,Error>?,continuation:CheckedContinuation<Data,Error>?
        func processExited() {lock.lock();exited=true;resumeIfReady()}
        func outputFinished(_ value:Result<Data,Error>) {lock.lock();output=value;resumeIfReady()}
        func wait(_ continuation:CheckedContinuation<Data,Error>) {lock.lock();self.continuation=continuation;resumeIfReady()}
        /// Requires the lock; releases it.
        private func resumeIfReady() {
            guard exited,let output,let continuation else {lock.unlock();return}
            self.continuation=nil;lock.unlock()
            continuation.resume(with:output)
        }
    }
    static func output(executable:URL,arguments:[String],input:Data)async throws->Data {
        let process=Process(),stdin=Pipe(),stdout=Pipe(),completion=Completion()
        process.executableURL=executable;process.arguments=arguments
        process.standardInput=stdin;process.standardOutput=stdout;process.standardError=FileHandle.nullDevice
        // Installed before launch so Foundation reports exit on GCD, never through a run loop.
        process.terminationHandler={_ in completion.processExited()}
        try process.run()
        stdin.fileHandleForReading.closeFile();stdout.fileHandleForWriting.closeFile()
        DispatchQueue.global(qos:.utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf:input);try? stdin.fileHandleForWriting.close()
            completion.outputFinished(Result {try stdout.fileHandleForReading.readToEnd() ?? Data()})
        }
        let data=try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {completion.wait($0)}
        } onCancel: {
            // This is only the child created above, never the user's Mail process.
            if process.isRunning {kill(process.processIdentifier,SIGKILL)}
        }
        try Task.checkCancellation()
        return data
    }
}

@MainActor enum MailScanWorker {
    static func run()->Int32 {
        // A UI quit must not leave a scanning child behind, even if the parent
        // exits before Swift cancellation gets another executor turn.
        let parent=getppid(),started=DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global(qos:.utility).async {
            while true {
                Thread.sleep(forTimeInterval:0.25)
                if getppid() != parent || DispatchTime.now().uptimeNanoseconds-started > 50_000_000_000 {_exit(124)}
            }
        }
        let response:MailScriptResponse
        do {
            guard Thread.isMainThread else{throw PortraitError.message("The Mail scanner started on an unexpected thread.")}
            let request=try JSONDecoder().decode(MailScriptRequest.self,from:FileHandle.standardInput.readDataToEndOfFile())
            let value:ScriptValue
            if request.handler == "fixture" {value = .list(request.arguments)}
            else {
                guard ["scaninventory","scanpageat","scanrecent","scanroutedinventory","scanroutedrecent","scanaccounts","scansentpage","scanrecentsent"].contains(request.handler) else{throw PortraitError.message("Unknown Mail scan operation.")}
                value=try execute(request.handler,arguments:request.arguments)
            }
            response=MailScriptResponse(value:value,error:nil,mainThread:Thread.isMainThread)
        } catch {response=MailScriptResponse(value:nil,error:error.localizedDescription,mainThread:Thread.isMainThread)}
        do {try FileHandle.standardOutput.write(contentsOf:JSONEncoder().encode(response));return response.error == nil ? 0 : 1}
        catch{return 1}
    }
    static func execute(_ handler:String,arguments:[ScriptValue])throws->ScriptValue {
        guard let script=NSAppleScript(source:MailScanScripts.source) else{throw PortraitError.message("The Mail scanner could not be initialized.")}
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        event.setDescriptor(ScriptValue.list(arguments).descriptor, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error) as NSAppleEventDescriptor?
        try Task.checkCancellation()
        guard error == nil, let result else {
            let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let detail = code == -1743 ? "Allow Apple Mail automation access. " : code == -1712 ? "The request timed out. Try again shortly. " : "The mailbox or message is temporarily unavailable. Try again shortly. "
            throw PortraitError.message("The Mail scan did not finish (\(code)）. \(detail)Imported senders are kept.")
        }
        return ScriptValue.read(result)
    }
}
