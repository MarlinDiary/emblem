import AppKit
import Combine
import Sparkle

/// The updater belongs to the visible application, never scanners/login agents.
/// Downloads and installation remain an explicit choice in Sparkle's native UI.
@MainActor final class SoftwareUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var available = false
    @Published var automaticChecks = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    private(set) var installationPending = false
    static func mayStart(arguments: [String], bundle: URL, ready: Bool) -> Bool {
        ready && bundle.pathExtension == "app" && !arguments.contains(where: { $0.hasPrefix("--") && $0 != "--appearance" && $0 != "--compact" })
    }
    func start(arguments: [String] = CommandLine.arguments, ready: Bool) {
        guard controller == nil, Self.mayStart(arguments:arguments,bundle:Bundle.main.bundleURL,ready:ready) else { return }
        let c = SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:self,userDriverDelegate:nil)
        controller=c
        automaticChecks=c.updater.automaticallyChecksForUpdates
        c.updater.publisher(for: \.canCheckForUpdates).receive(on:RunLoop.main).sink { [weak self] in self?.available=$0 }.store(in:&observations)
        do { try c.updater.start() }
        catch { controller=nil; available=false; BackgroundLifecycle.model?.errorText="Update checking: "+error.localizedDescription }
    }
    func check() { controller?.checkForUpdates(nil) }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { installationPending=true }
}
