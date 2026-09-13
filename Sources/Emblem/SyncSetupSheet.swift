import SwiftUI

struct SyncSetupSheet:View {
    @ObservedObject var model:AppModel
    @State private var includeExisting=false
    @State private var working=false
    @State private var background=false
    @State private var portraits=true
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Keep sender photos up to date").font(.title2.weight(.semibold))
            Text("Add new senders to Contacts automatically. Existing personal photos stay unchanged unless you choose a replacement.").foregroundStyle(.secondary)
            Toggle("Include \(model.activeCount) existing sender addresses",isOn:$includeExisting)
            Toggle("Continue after quitting",isOn:$background)
            Toggle("Find public portraits with Gravatar and Libravatar",isOn:$portraits)
            Text("Websites receive lookup requests. Portrait services receive email hashes, which are not anonymous. Ignoring a sender stops sync and reverses this app’s changes when possible; your original contacts are preserved.").font(.caption).foregroundStyle(.secondary)
            if let error {Text(error).font(.caption).foregroundStyle(.red)}
            HStack {
                Button("Not Now") {model.showSyncSetup=false}.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Enable Automatic Sync") {
                    working=true
                    Task {do {try await model.enableMailSync(includeExisting:includeExisting);model.useGravatar=portraits;model.setBackground(background);model.showSyncSetup=false;model.automaticTick();model.kickMailSync()}catch{self.error=error.localizedDescription};working=false}
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(working)
            }
        }.onAppear {background=model.mailSync.background;if model.automation.setupComplete {portraits=model.useGravatar}}
            .padding(28).frame(width:460).fixedSize(horizontal:false,vertical:true)
    }
}
