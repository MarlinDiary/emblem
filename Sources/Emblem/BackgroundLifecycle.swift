import AppKit

/// Cmd-Q ends this foreground process. An explicitly registered OS background
/// agent may later acquire the released library lease and continue synchronization.
@MainActor final class BackgroundLifecycle:NSObject,NSApplicationDelegate {
    static weak var model:AppModel?
    static weak var session:AppSession?
    static weak var updates:SoftwareUpdates?
    private var quitTask:Task<Void,Never>?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {
        !(Self.model?.mailSync.background ?? false)
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool {
        if !hasVisibleWindows {sender.windows.first{$0.identifier?.rawValue=="main"}?.makeKeyAndOrderFront(nil)}
        return true
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard quitTask == nil else{return .terminateLater}
        guard let session=Self.session else{return .terminateNow}
        quitTask=Task {
            do {
                try await session.prepareToQuit(installingUpdate:Self.updates?.installationPending == true)
                sender.reply(toApplicationShouldTerminate:true)
            } catch {
                Self.model?.isShuttingDown=false
                Self.model?.errorText="Your library needs to be saved before quitting: "+error.localizedDescription
                await BackgroundService.update(for:session.model)
                quitTask=nil;sender.reply(toApplicationShouldTerminate:false)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification:Notification) {
        Self.model?.isShuttingDown=true;Self.model?.stopAutomaticWork();Self.model?.stopGmailPushListening();Self.model?.syncTask?.cancel();Self.model?.save()
    }
}
