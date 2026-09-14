import AppKit

/// Cmd-Q ends this foreground process. An explicitly registered OS background
/// agent may later acquire the released library lease and continue synchronization.
@MainActor final class BackgroundLifecycle:NSObject,NSApplicationDelegate {
    static weak var model:AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {
        !(Self.model?.mailSync.background ?? false)
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool {
        if !hasVisibleWindows {sender.windows.first{$0.identifier?.rawValue=="main"}?.makeKeyAndOrderFront(nil)}
        return true
    }
    func applicationWillTerminate(_ notification:Notification) {
        Self.model?.isShuttingDown=true;Self.model?.stopAutomaticWork();Self.model?.stopGmailPushListening();Self.model?.syncTask?.cancel();Self.model?.save()
    }
}
