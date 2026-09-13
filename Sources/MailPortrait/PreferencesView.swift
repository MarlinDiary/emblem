import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @State private var confirmPortraitServices=false
    @State private var disconnectID:String?
    private var version:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "Development"}
    var body: some View {
        TabView {
            Form {
                Section("Accounts") {
                    Toggle("Use Apple Mail as needed",isOn:$model.automation.mail)
                    ForEach(model.gmail.accounts) { account in
                        LabeledContent {
                            Button("Disconnect") {disconnectID=account.id}.controlSize(.small)
                        } label: {
                            VStack(alignment:.leading,spacing:3) {
                                Text(account.email).lineLimit(1)
                                if let issue=account.issue {Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                                else {Text("Gmail · Connected").font(.caption).foregroundStyle(.secondary)}
                            }
                        }
                    }
                    if model.gmailConnecting {
                        HStack {Text("Finish signing in with Google").foregroundStyle(.secondary);Spacer();Button("Cancel") {model.gmailAuthorization.cancel();model.gmailSignInTask?.cancel()}}
                    } else {Button("Connect Gmail…") {model.connectGmail()}.disabled(model.demo)}
                    Text("Connected Gmail accounts are checked directly. Apple Mail covers other accounts and takes over if Gmail needs to retry.").font(.caption).foregroundStyle(.secondary)
                    if let issue=model.gmailIssue {Text(issue).font(.caption).foregroundStyle(.orange)}
                }
                Section("Sync") {
                    Toggle("Automatically update Contacts",isOn:Binding(get:{model.mailSync.enabled},set:{model.setMailSyncEnabled($0)}))
                    Toggle("Continue after quitting",isOn:Binding(get:{model.mailSync.background},set:{model.setBackground($0)}))
                    Text("Starts at login without opening a window.").font(.caption).foregroundStyle(.secondary)
                    Text("New senders are added automatically. Existing personal photos stay unchanged unless you choose another photo.").font(.caption).foregroundStyle(.secondary)
                    if let issue=model.backgroundServiceIssue {Text(issue).font(.caption).foregroundStyle(.orange)}
                    if model.backgroundServiceNeedsApproval {Button("Allow Background Activity") {BackgroundService.openSettings()}}
                    if let issue=model.syncAttention {Text(issue).font(.caption).foregroundStyle(.orange)}
                }
            }.formStyle(.grouped).tabItem {Label("General",systemImage:"gearshape")}
            Form {
                Section("Photo Sources") {
                    Toggle("Websites and public profiles",isOn:$model.useWebsite)
                    Toggle("Gravatar and Libravatar",isOn:Binding(get:{model.useGravatar},set:{on in if on {confirmPortraitServices=true} else {model.useGravatar=false}}))
                    Text("Portrait services receive email hashes, which are not anonymous. You can turn them off at any time.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("How photo lookup works") {
                        Text("Website requests use the sender’s domain. BIMI uses DNS; icon hosts receive image requests. Public directories may receive a name or profile identifier. General profile matches require the exact email and name on an organization’s public website. Google Site Icon is used only as a domain-only fallback.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("On This Mac") {
                    Text("No analytics or project-hosted address book. Gmail requests sender headers, dates and inbox metadata—not message bodies, subjects or attachments. Credentials stay in Keychain.").font(.caption).foregroundStyle(.secondary)
                    HStack {Button("Show Data Folder") {NSWorkspace.shared.open(model.root)};Spacer();Button("Undo Changes…") {model.showHistoryTools=true}}
                    Text("Ignoring a sender stops sync and reverses this app’s changes when possible. Your original contacts and externally edited cards are preserved.").font(.caption).foregroundStyle(.secondary)
                }
                Section {Text("MailPortrait \(version) · Open source, MIT").font(.caption).foregroundStyle(.tertiary)}
            }.formStyle(.grouped).tabItem {Label("Privacy",systemImage:"hand.raised")}
        }
        .sheet(isPresented:$model.showSyncSetup) {SyncSetupSheet(model:model)}
        .sheet(isPresented:$model.showHistoryTools) {
            VStack {HSplitView {HistoryList(model:model).frame(width:230);HistoryDetail(model:model)};Button("Done") {model.showHistoryTools=false}.padding()}.frame(width:760,height:540)
                .alert("Undo this change?",isPresented:Binding(get:{model.undoRecord != nil},set:{if !$0{model.undoRecord=nil}})) {
                    Button("Cancel",role:.cancel){model.undoRecord=nil}
                    Button("Undo",role:.destructive){if let r=model.undoRecord{model.undo(r)};model.undoRecord=nil}
                } message:{Text("Only an unmodified contact created by this app may be deleted. iCloud syncs the change to your other devices.")}
        }
        .alert("Enable portrait services?",isPresented:$confirmPortraitServices) {
            Button("Cancel",role:.cancel){}
            Button("Enable") {model.useGravatar=true;model.automaticTick()}
        } message:{Text("Gravatar and Libravatar will receive hashes of sender email addresses to find public photos. Hashes are not anonymous. Existing photos and manual choices are preserved.")}
        .alert("Disconnect Gmail?",isPresented:Binding(get:{disconnectID != nil},set:{if !$0 {disconnectID=nil}})) {
            Button("Cancel",role:.cancel) {disconnectID=nil}
            Button("Disconnect",role:.destructive) {if let id=disconnectID {model.disconnectGmail(id)};disconnectID=nil}
        } message:{Text("Remove the saved credentials from this Mac and stop checking this account. Discovered senders and Contacts remain. You can also revoke access in your Google Account.")}
        .onChange(of:model.automation.mail) {_,_ in model.stopAutomaticWork();model.saveAutomationPreferences();model.automaticTick()}
    }
}

struct HelpView:View {
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("MailPortrait Help").font(.largeTitle.weight(.bold))
                help("Connect an account", "Use Apple Mail, or connect Gmail directly in Settings. Google sign-in is completed in your browser. Contacts access is requested by macOS.")
                help("Choose a photo", "Click a photo to use it. With automatic sync enabled, the change appears in Contacts without another Apply step. Existing personal photos and your manual choices are preserved.")
                help("Keep it automatic", "Enable Continue after quitting to let macOS check for new senders after Cmd-Q. Checks are approximately once a minute, with retries when needed. This is not instant push; sleep and logout pause work.")
                help("Ignore or undo", "Ignore stops maintaining a sender and reverses this app’s changes when possible. Only unmodified cards created by this app are deleted. Use View → Show Ignored Senders to restore them, or Settings → Privacy → Undo Changes for history.")
                Text("Photos help you recognize senders. They do not verify identity. MailPortrait is independent of Apple.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
    private func help(_ title:String,_ body:String)->some View {VStack(alignment:.leading,spacing:6){Text(title).font(.headline);Text(body).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}}
}
