import AppKit
import Carbon
import PortraitCore

/// A real accessory application can service LaunchServices reopen events while
/// keeping its sockets windowless and outside the Dock. Never create SwiftUI.
@MainActor final class AgentApplication:NSObject,NSApplicationDelegate {
    private static var retained:AgentApplication?
    private var opening=false
    private let opener: (@escaping ()->Void)->Void
    init(opener: @escaping (@escaping ()->Void)->Void) {self.opener=opener}
    func applicationOpenUntitledFile(_ sender:NSApplication)->Bool {false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool {
        requestOpen();return false
    }
    func requestOpen() {
        guard !opening else{return}
        opening=true;opener { [weak self] in self?.opening=false }
    }
    private static func openForeground(done:@escaping ()->Void) {
        if let id=Bundle.main.bundleIdentifier,
           let foreground=NSRunningApplication.runningApplications(withBundleIdentifier:id).first(where:{$0.processIdentifier != getpid() && $0.activationPolicy == .regular}) {
            let target=NSAppleEventDescriptor(processIdentifier:foreground.processIdentifier)
            let event=NSAppleEventDescriptor(eventClass:AEEventClass(kCoreEventClass),eventID:AEEventID(kAEReopenApplication),targetDescriptor:target,returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
            _=try? event.sendEvent(options:[.noReply,.neverInteract],timeout:1)
            foreground.activate(options:.activateAllWindows);done();return
        }
        let config=NSWorkspace.OpenConfiguration();config.createsNewApplicationInstance=true
        config.activates=true
        NSWorkspace.shared.openApplication(at:Bundle.main.bundleURL,configuration:config) { _,_ in
            Task { @MainActor in done() }
        }
    }
    static func run(arguments:[String]) {
        let fixture=arguments.contains("--agent-application-fixture")
        if fixture {
            guard let i=arguments.firstIndex(of:"--data-dir"),i+1<arguments.count,
                  URL(fileURLWithPath:arguments[i+1]).standardizedFileURL != LibraryLease.liveRoot.standardizedFileURL else {exit(64)}
        }
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        var unexpectedOpens=0
        let delegate:AgentApplication
        if fixture {delegate=AgentApplication {done in unexpectedOpens+=1;done()}}
        else {delegate=AgentApplication(opener:openForeground)}
        retained=delegate;app.delegate=delegate
        Task {
            if fixture {
                try? await Task.sleep(for:.milliseconds(300))
                guard app.activationPolicy() == .accessory,app.windows.isEmpty,unexpectedOpens==0 else {exit(1)}
                print("AGENT_BOOT=PASS POLICY=accessory WINDOWS=0 FOREGROUND_LAUNCHES=0 UPDATER=0 CONTACT_WRITES=0");exit(0)
            }
            exit(await BackgroundSyncAgent.run(arguments:arguments))
        }
        app.run();exit(1)
    }
}
