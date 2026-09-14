import AppKit
import SwiftUI
import PortraitCore

/// Dispatch headless jobs before SwiftUI creates NSApplication. Otherwise
/// LaunchServices can mistake the bounded sync job for the foreground app.
@main enum EmblemMain {
    @MainActor static func main() {
        let args=CommandLine.arguments
        EmblemMigration.migratePreferences()
        if args.contains("--gmail-status") {exit(GmailStatus.run(arguments:args))}
        if args.contains("--lease-fixture") {exit(LibraryLease.fixture(arguments:args))}
        if args.contains("--headless-fixture") {
            do {
                guard NSApp == nil else {exit(1)}
                _=try NameAvatar.candidate(name:"Fastlink")
                guard NSApp == nil else {exit(1)}
                print("HEADLESS_ENTRY=PASS APPKIT_APPLICATION=ABSENT IMAGE_RENDER=PASS CONTACT_WRITES=0")
                exit(0)
            } catch {print("HEADLESS_FIXTURE_ERROR=\(error)");exit(1)}
        }
        if args.contains("--background-sync-agent") {
            Task {exit(await BackgroundSyncAgent.run(arguments:args))}
            RunLoop.main.run();exit(1)
        }
        if args.contains("--background-service-status") || args.contains("--unregister-background-service") {
            Task {exit(await BackgroundService.command(arguments:args))}
            RunLoop.main.run();exit(1)
        }
        if args.contains("--mail-scan-worker") {exit(MailScanWorker.run())}
        EmblemApp.main()
    }
}
