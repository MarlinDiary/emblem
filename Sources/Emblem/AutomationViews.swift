import SwiftUI

struct AutomaticSetupSheet:View {
    @ObservedObject var model:AppModel
    @State private var portraits=true
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            SheetHeading(symbol:"person.crop.circle.badge.checkmark",title:"Find familiar faces",subtitle:"Discover senders, match existing contacts, and find clear photos automatically.")
            Toggle("Use Gravatar and Libravatar",isOn:$portraits)
            Text("Websites and public directories receive lookup requests. Portrait services receive email hashes, which are not anonymous. Existing photos and manual choices are preserved.").font(.caption).foregroundStyle(.secondary)
            HStack {Button("Not Now") {model.showAutomaticSetup=false}.keyboardShortcut(.cancelAction);Spacer();Button("Continue") {model.useGravatar=portraits;model.enableAutomaticSetup()}.portraitAction(prominent:true).keyboardShortcut(.defaultAction)}
        }.padding(28).frame(width:440)
    }
}
struct AutomaticStatusView:View {
    @ObservedObject var model:AppModel
    var body:some View {
        if !model.automation.setupComplete {Button("Get Started") {model.showAutomaticSetup=true}.portraitAction()}
    }
}
