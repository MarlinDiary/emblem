import SwiftUI
import AppKit
import PortraitCore

struct EmblemApp: App {
    @NSApplicationDelegateAdaptor(BackgroundLifecycle.self) private var lifecycle
    @StateObject private var session: AppSession
    init() {
        let args = CommandLine.arguments
        if args.contains("--diagnose-receipt-order") {Task {exit(await ReceiptOrderDiagnostics.run(arguments:args))};RunLoop.main.run()}
        if args.contains("--restore-protected-photo") {exit(PhotoRecovery.run(arguments:args))}
        if args.contains("--sync-fixture-smoke") {Task {exit(await SyncFixtureSmoke.run(arguments:args))};RunLoop.main.run()}
        if args.contains("--diagnose-contact-undo") { exit(UndoDiagnostics.run(arguments:args)) }
        if args.contains("--self-test") { exit(SelfTest.run(arguments: args)) }
        if args.contains("--rollback-fixture") { exit(SelfTest.rollback(arguments: args)) }
        if args.contains("--live-sources-smoke") { LiveSourcesSmoke.run(); exit(0) }
        if args.contains("--live-profile-brand-smoke") { LiveProfileBrandSmoke.run(arguments: args); exit(0) }
        if args.contains("--live-v091-smoke") { LiveV091Smoke.run(arguments: args); exit(0) }
        if args.contains("--live-v092-smoke") { LiveV092Smoke.run(arguments: args); exit(0) }
        if args.contains("--live-v093-smoke") { LiveV093Smoke.run(arguments: args); exit(0) }
        if args.contains("--live-v094-smoke") { LiveV094Smoke.run(arguments: args); exit(0) }
        if args.contains("--v094-state-smoke") { exit(V094StateSmoke.run(arguments: args)) }
        if args.contains("--live-icon-smoke") { LiveIconSmoke.run(); exit(0) }
        // The bundle starts as an agent so disposable Mail scanners and the
        // login helper never enter the Dock. Only a visible session is promoted;
        // diagnostics above must remain agent-only as well.
        NSApplication.shared.setActivationPolicy(.regular)
        _session = StateObject(wrappedValue: AppSession(arguments: args))
    }
    var body: some Scene {
        Window("Emblem", id: "main") {
            Group {
                if session.isReady {MainView(model:session.model,session:session)}
                else {VStack(spacing:12) {if let error=session.initializationError {Text(error)} else {ProgressView();Text("Opening Your Library").foregroundStyle(.secondary)}}}
            }.frame(minWidth:900,minHeight:620).preferredColorScheme(session.appearance)
        }
        .defaultSize(width: session.size.width, height: session.size.height)
        .windowToolbarStyle(.automatic)
        .commands {
            CommandGroup(replacing: .appTermination) { Button("Quit Emblem") {NSApp.terminate(nil)}.keyboardShortcut("q") }
            CommandGroup(after: .sidebar) {
                Button(session.model.section == "ignored" ? "Show All Senders" : "Show Ignored Senders") {session.model.section = session.model.section == "ignored" ? "all" : "ignored"}
            }
            CommandGroup(after: .newItem) {
                Button("Add Senders…") { session.model.showImport = true }.keyboardShortcut("n").disabled(session.model.busy)
                Button("Scan Senders…") { session.model.showScan = true }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(session.model.busy || session.model.isScanning)
                Button("Import Selected Mail Messages") { session.model.importFromMail() }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(session.model.busy)
            }
            CommandMenu("Photos") {
                Button("Apply All") { session.model.prepareBatch(ids: session.model.batchScopeIDs) }
                    .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(session.model.busy || session.model.isScanning || session.model.batchScopeIDs.isEmpty)
                Button("Select Multiple Senders") { session.model.batchMode.toggle();session.model.selectedForBatch.removeAll() }
                    .keyboardShortcut("m",modifiers:[.command,.shift]).disabled(session.model.section == "history")
                Divider()
                Button("Find Photos…") { if let id = session.model.selectedID { session.model.requestLookup(ids: [id]) } }
                    .keyboardShortcut("r").disabled(session.model.selected == nil || session.model.busy)
                Button("Choose Photo…") { session.model.chooseFile() }.disabled(session.model.selected == nil || session.model.busy)
                Divider()
                Button("Refresh Contacts") { session.model.connectContacts() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(session.model.busy)
            }
            CommandGroup(replacing: .help) {
                HelpCommand()
            }
            CommandGroup(after: .windowArrangement) { MainWindowCommand() }
        }
        Settings {
            PreferencesView(model: session.model).frame(width: 550, height: 480).preferredColorScheme(session.appearance)
        }
        Window("Photo Sources · Emblem", id: "sources") { SourcePreviewView(model: session.model).frame(minWidth: 820, minHeight: 600).preferredColorScheme(session.appearance) }.defaultSize(width: 1000, height: 760)
        Window("Emblem Help", id: "help") { HelpView().frame(minWidth: 480, minHeight: 500) }.defaultSize(width: 540, height: 620)
    }
}

struct HelpCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Emblem Help") { openWindow(id: "help") } }
}

struct MainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Main Window") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("1")
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: AppSession
    @State private var visibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SenderList(model:model)
                .navigationTitle(model.sectionTitle)
                .navigationSplitViewColumnWidth(min:280,ideal:310,max:380)
                .overlay(alignment:.trailing) {SidebarBoundary()}
        } detail: {
            Group {
                if let row=model.selected {SenderDetail(model:model,row:row).id(row.id)}
                else {WelcomeView(model:model,session:session)}
            }.frame(minWidth:350,maxWidth:.infinity,maxHeight:.infinity)
        }
        // Stable root ownership: changing a detail's .id must not detach the
        // window toolbar or the system search field.
        .toolbar {
            ToolbarItem(id:"refresh-avatar",placement:.primaryAction) {
                if let row=model.selected,!row.ignored {
                    Button("Find Again",systemImage:"arrow.clockwise") {model.requestLookup(ids:model.selectedGroup?.members.map(\.id) ?? [row.id])}
                        .labelStyle(.iconOnly).help("Find Photos Again").disabled(model.busy)
                }
            }
            ToolbarItem(id:"ignore-sender",placement:.primaryAction) {
                if let row=model.selected {
                    Button(row.ignored ? "Restore Sender" : "Ignore Sender",systemImage:row.ignored ? "arrow.uturn.backward" : "eye.slash") {
                        let ids=model.selectedGroup?.emailIDs ?? [row.id]
                        if row.ignored {model.restoreIgnored(ids)}
                        else {Task {do{try await model.ignoreSyncedSenders(ids)}catch{model.errorText=error.localizedDescription}}}
                    }.labelStyle(.iconOnly).disabled(model.busy)
                }
            }
            ToolbarItem(id:"sync-setup",placement:.secondaryAction) {
                if !model.mailSync.enabled {Button("Enable Automatic Sync",systemImage:"arrow.triangle.2.circlepath") {model.showSyncSetup=true}.labelStyle(.iconOnly).help("Enable Automatic Sync")}
            }

            ToolbarItem(id:"batch-apply",placement:.primaryAction) {
                if model.showsBatchAction {
                    Button(model.batchMode ? "Apply Selected" : "Apply All") { model.prepareBatch(ids:model.batchScopeIDs) }
                        .portraitAction(prominent:true).disabled(model.busy || model.isScanning || model.discoveryTask != nil)
                }
            }
            ToolbarItem(id:"finish-selection",placement:.secondaryAction) {
                if model.batchMode { Button("Done") { model.batchMode=false;model.selectedForBatch.removeAll() } }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge:.bottom,spacing:0) {
            if !model.lastIgnoredIDs.isEmpty {
                HStack {Text("Ignored").foregroundStyle(.secondary);Spacer();Button("Undo") {model.restoreIgnored(model.lastIgnoredIDs)}}.font(.callout).padding(12)
            }
            BatchProgressStrip(model:model)
        }
        .searchable(text: $model.search, prompt: Text("Search"))
        .onChange(of: model.section) { _, _ in model.reconcileSelection() }
        .onChange(of: model.search) { _, _ in model.reconcileSelection() }
        .onChange(of: model.selectedID) { _, _ in model.websiteOverride = "" }
        .task {
            BackgroundLifecycle.model=model
            guard model.backgroundWorkAllowed else{return}
            if CommandLine.arguments.contains("--ui-experience-smoke") {
                model.automaticEnabled=false
                exit(await NativeExperienceSmoke.run(model:model))
            }
            await model.prepareAvatarQuality();await model.prepareNameFallbacks()
            model.automaticTick();await model.refreshCanvasOriginals()
        }
        .sheet(isPresented:$model.showSyncSetup) {SyncSetupSheet(model:model)}
        .sheet(isPresented: $model.showAutomaticSetup) { AutomaticSetupSheet(model:model) }
        .sheet(isPresented: $model.showScan) { ScanSheet(model:model) }
        .sheet(isPresented: $model.showImport) { ImportSheet(model: model) }
        .sheet(isPresented: $model.showBatchConfirmation) { BatchApplySheet(model: model) }
        .sheet(isPresented: $model.showBatchIssues) { BatchIssuesSheet(model: model) }
        .sheet(isPresented: $model.showApplyConfirmation) { ApplySheet(model: model) }
        .sheet(isPresented: $model.showSourceConsent) { SourceConsentSheet(model: model) }
        .sheet(isPresented: $model.showContactConsent) { ContactConsentSheet(model: model) }
        .alert("Undo These Changes?", isPresented: Binding(get: { model.undoBatchID != nil }, set: { if !$0 { model.undoBatchID = nil } })) {
            Button("Cancel", role: .cancel) { model.undoBatchID = nil }
            Button("Undo Batch", role: .destructive) { if let id = model.undoBatchID { model.undoBatch(id) }; model.undoBatchID = nil }
        } message: {
            Text("Restore previous photos and remove only unchanged contacts created by this batch. iCloud syncs deletions; later edits are preserved.")
        }
        .alert("Something Needs Attention", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("OK", role: .cancel) { model.errorText = nil }
        } message: { Text(model.errorText ?? "") }
        .alert(model.undoRecord?.created == true ? "Delete This Contact?" : "Undo This Photo Change?", isPresented: Binding(get: { model.undoRecord != nil }, set: { if !$0 { model.undoRecord = nil } })) {
            Button("Cancel", role: .cancel) { model.undoRecord = nil }
            Button(model.undoRecord?.created == true ? "Delete Contact" : "Undo Photo", role: .destructive) {
                if let record = model.undoRecord { model.undo(record) }; model.undoRecord = nil
            }
        } message: {
            Text(model.undoRecord?.created == true ? "Delete the contact created by this app: \(model.undoRecord?.email ?? ""). iCloud syncs the deletion to other devices. A contact edited elsewhere is preserved.\(model.demo ? "\nDemo mode only changes the separate test library." : "")" : "Restore the previous photo and keep the contact. Later photo changes are preserved.")
        }
    }
}
