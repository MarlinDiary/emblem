import PortraitCore

import SwiftUI
import AppKit
import Contacts
import Combine

@MainActor final class AppSession: ObservableObject {
    @Published var model: AppModel
    @Published var isReady=true
    @Published var initializationError:String?
    private var lease:LibraryLease?
    private var startupTask:Task<Void,Never>?
    private var placeholderRoot:URL?
    private let liveForeground:Bool
    let appearance: ColorScheme?
    let size: CGSize
    private var timer: AnyCancellable?
    private var observers = Set<AnyCancellable>()
    private let initialDemo: Bool
    private let rootOverride: URL?
    private let isolatedRoot: URL?
    init(arguments: [String] = CommandLine.arguments, isolatedRoot: URL? = nil) {
        self.isolatedRoot = isolatedRoot
        let demo = arguments.contains("--demo")
        initialDemo = demo
        rootOverride = arguments.firstIndex(of: "--data-dir").flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true) : nil }
        let color = arguments.firstIndex(of: "--appearance").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        appearance = color == "dark" ? .dark : color == "light" ? .light : nil
        size = arguments.contains("--compact") ? CGSize(width: 960, height: 660) : CGSize(width: 1160, height: 760)
        liveForeground = !demo && rootOverride == nil && isolatedRoot == nil
        if liveForeground {
            // Do not load or write the live library until the agent yields its lease.
            let placeholder=FileManager.default.temporaryDirectory.appendingPathComponent("emblem-opening-"+UUID().uuidString)
            placeholderRoot=placeholder
            model=AppModel(demo:true,rootOverride:placeholder,backgroundWorkAllowed:false)
            model.busy=true;isReady=false
        } else {model = AppModel(demo: demo, rootOverride: isolatedRoot?.appendingPathComponent(demo ? "demo" : "main") ?? rootOverride)}
        if demo && model.rows.isEmpty { model.loadDemo() }
        timer = Timer.publish(every:30,on:.main,in:.common).autoconnect().sink { [weak self] _ in guard let self,self.isReady else{return};self.model.automaticTick() }
        NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor in guard let self,self.isReady else{return};self.model.automaticTick() }
        }.store(in:&observers)
        NotificationCenter.default.publisher(for:.CNContactStoreDidChange).sink { [weak self] _ in
            Task { @MainActor in guard let self,self.isReady else{return};self.model.contactsDidChange() }
        }.store(in:&observers)
        if liveForeground {startupTask=Task {await openLiveLibrary()}}
    }
    private func openLiveLibrary()async {
        do {
            let root=try EmblemMigration.migrateLibraryIfNeeded()
            await EmblemMigration.unregisterLegacyBackgroundService()
            try LibraryLease.requestForeground(root:root)
            defer {LibraryLease.clearOwnRequest(root:root)}
            let deadline=Date().addingTimeInterval(180)
            while lease == nil {
                try Task.checkCancellation()
                lease=try LibraryLease.acquire(root:root)
                if lease != nil {break}
                guard Date()<deadline else {throw PortraitError.message("Background sync is taking longer than expected. Close and reopen Emblem to retry; your library is unchanged.")}
                try await Task.sleep(for:.milliseconds(100))
            }
            model=AppModel(demo:false,rootOverride:root)
            model.backgroundPreferenceChanged={ [weak self] in
                guard let self else{return}
                Task {await BackgroundService.update(for:self.model)}
            }
            if let placeholderRoot {try? FileManager.default.removeItem(at:placeholderRoot);self.placeholderRoot=nil}
            isReady=true
            await BackgroundService.update(for:model)
            if model.mailSync.enabled && CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                // A renamed app can be re-evaluated by TCC even when its stable
                // compatibility identity is unchanged. Ask once from the visible
                // foreground window; unattended jobs never enter this path.
                model.connectContacts()
            }
        } catch {initializationError=error.localizedDescription}
    }
    func switchMode(demo: Bool) {
        guard !model.busy, !model.isScanning, model.discoveryTask == nil, model.demo != demo else { return }
        model.stopAutomaticWork();model.syncTask?.cancel()
        model = AppModel(demo: demo, rootOverride: isolatedRoot?.appendingPathComponent(demo ? "demo" : "main") ?? (demo == initialDemo ? rootOverride : nil))
        if demo && model.rows.isEmpty { model.loadDemo() }
        if liveForeground && !demo {
            model.backgroundPreferenceChanged={ [weak self] in guard let self else{return};Task {await BackgroundService.update(for:self.model)} }
            Task {await BackgroundService.update(for:model)}
        }
    }
}
