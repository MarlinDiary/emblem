import AppKit
import ServiceManagement

/// Registered with the OS and visible in Login Items, not a hidden survive-quit process.
@MainActor enum BackgroundService {
    static let plistName="org.mailportrait.sync.plist"
    static let registeredBuildKey="MailPortraitBackgroundServiceRegisteredBuild"
    static var service:SMAppService {SMAppService.agent(plistName:plistName)}
    static var currentBuild:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "development"}
    static func shouldRefreshRegistration(isEnabled:Bool,registeredBuild:String?,currentBuild:String)->Bool {
        isEnabled && registeredBuild != currentBuild
    }
    static func update(for model:AppModel)async {
        do {
            if model.mailSync.background && model.mailSync.enabled {
                let defaults=UserDefaults.standard
                if shouldRefreshRegistration(isEnabled:service.status == .enabled,registeredBuild:defaults.string(forKey:registeredBuildKey),currentBuild:currentBuild) {
                    try await service.unregister()
                    try service.register()
                } else if service.status == .notRegistered || service.status == .notFound {try service.register()}
                if service.status == .enabled {defaults.set(currentBuild,forKey:registeredBuildKey)}
                model.backgroundServiceNeedsApproval=service.status == .requiresApproval
                model.backgroundServiceIssue=service.status == .enabled ? nil : service.status == .requiresApproval ? "Allow MailPortrait background activity in System Settings." : "Background activity is not enabled."
            } else {
                if service.status == .enabled || service.status == .requiresApproval {try await service.unregister()}
                UserDefaults.standard.removeObject(forKey:registeredBuildKey)
                model.backgroundServiceNeedsApproval=false;model.backgroundServiceIssue=nil
            }
        } catch {model.backgroundServiceIssue="Background service: "+error.localizedDescription+" (\((error as NSError).domain):\((error as NSError).code))"}
    }
    static func command(arguments:[String])async->Int32 {
        do {
            if arguments.contains("--unregister-background-service") {try await service.unregister();UserDefaults.standard.removeObject(forKey:registeredBuildKey)}
            print("BACKGROUND_SERVICE_STATUS=\(service.status.rawValue)")
            return 0
        } catch {print("BACKGROUND_SERVICE_ERROR=\(error.localizedDescription)");return 1}
    }
    static func openSettings(){SMAppService.openSystemSettingsLoginItems()}
}
