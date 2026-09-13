import SwiftUI

struct ScanSheet:View {
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Import Senders").font(.title2.weight(.semibold))
            Picker("Source",selection:$model.scanSource) {ForEach(ScanSource.allCases) {Text($0.title).tag($0)}}
            Text(model.scanSource == .contacts ? "Read names, email addresses and photo thumbnails from Contacts." : "Read sender metadata from Apple Mail. Subjects, message bodies and attachments are not read, and messages are not marked as read.")
                .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text("Senders appear as they are found. Photo lookup and Contacts updates follow your automatic sync settings. Gmail is connected separately in Settings.").font(.caption).foregroundStyle(.secondary)
            HStack {Button("Cancel") {model.showScan=false}.keyboardShortcut(.cancelAction);Spacer();Button("Import") {model.startScan(model.scanSource)}.keyboardShortcut(.defaultAction).portraitAction(prominent:true)}
        }.padding(28).frame(width:440)
    }
}
struct ScanStatusView:View {
    @ObservedObject var model:AppModel
    @State private var showReport=false
    var body:some View {
        if let report=model.scanReport {
            HStack {
                Text(model.isScanning ? "Importing Senders":"Import Finished").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isScanning {Button("Stop") {model.cancel()}.disabled(model.scanStopping).buttonStyle(.borderless)}
                else {Button("Details") {showReport=true}.buttonStyle(.borderless)}
            }.padding(12)
                .sheet(isPresented:$showReport) {
                    VStack(alignment:.leading,spacing:18) {
                        Text("Import Summary").font(.title2.weight(.semibold))
                        Form {
                            LabeledContent("Source",value:report.source.title)
                            LabeledContent("Checked",value:"\(report.examined)")
                            LabeledContent("Added",value:"\(report.added)")
                            LabeledContent("Already in Library",value:"\(report.existing)")
                            if report.invalid>0 {LabeledContent("Unrecognized",value:"\(report.invalid)")}
                            if !report.warnings.isEmpty {Text("Some items could not be read. Imported senders are kept; another check can fill the gaps.").font(.caption).foregroundStyle(.secondary)}
                        }.formStyle(.grouped)
                        HStack {Spacer();Button("Done") {showReport=false}.keyboardShortcut(.defaultAction)}
                    }.padding(24).frame(width:440,height:380)
                }
        }
    }
}
