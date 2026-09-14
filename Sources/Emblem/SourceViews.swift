import SwiftUI
import AppKit
import PortraitCore

struct SourceReportsView: View {
    let reports: [SourceReport]
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            ForEach(reports) { report in
                HStack(alignment:.top,spacing:12) {
                    Image(systemName:report.source.symbol).font(.system(size:16)).foregroundStyle(.secondary).frame(width:22)
                    VStack(alignment:.leading,spacing:5) {
                        HStack {
                            Text(report.source.title).font(.callout.weight(.medium))
                            Spacer()
                            Label(outcome(report),systemImage:report.outcome == .found ? "checkmark.circle.fill" : report.outcome == .unavailable ? "exclamationmark.circle" : "minus.circle")
                                .font(.caption).foregroundStyle(report.outcome == .found ? .green : .secondary)
                        }
                        Text(report.outcome == .found ? "A matching public image was found." : report.outcome == .missing ? "No suitable public photo was found." : report.outcome == .skipped ? "This source was not queried." : "This source did not finish. It can be retried.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
        }
    }
    private func outcome(_ report:SourceReport) -> String {
        switch report.outcome { case .found: return report.count > 0 ? "\(report.count) photos" : "Found"; case .missing: return "Not Found"; case .skipped: return "Skipped"; case .unavailable: return "Not Completed" }
    }
}

struct SourceWindowCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Preview Website Photos…",systemImage:"globe") { openWindow(id:"sources"); NSApp.activate(ignoringOtherApps:true) } }
}

@MainActor final class SourcePreviewModel: ObservableObject {
    @Published var website = "https://github.com"
    @Published var result: LookupResult?
    @Published var selectedID: UUID?
    @Published var busy = false
    @Published var error: String?
    private var task: Task<Void,Never>?
    var selected: AvatarCandidate? { result?.candidates.first { $0.id == selectedID } }
    func lookup() {
        guard !busy, let url=WebsiteAddress.parse(website) else { return }
        busy=true; result=nil; selectedID=nil; error=nil
        task=Task {
            defer { busy=false; task=nil }
            do {
                let found=try await AvatarResolver().resolveWebsite(at:url)
                try Task.checkCancellation()
                result=found; selectedID=found.candidates.first?.id
                if found.candidates.isEmpty { error="No suitable icon was found. Try the official website or choose a local photo." }
            } catch is CancellationError { error="Lookup stopped." }
            catch { self.error=error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
}

struct SourcePreviewView:View {
    @StateObject private var preview=SourcePreviewModel()
    @ObservedObject var model:AppModel
    @State private var showAll=false
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("Website Photos").font(.title2.weight(.semibold))
                HStack {
                    TextField("Website address",text:$preview.website).textFieldStyle(.roundedBorder).onSubmit {preview.lookup()}
                    Button("Find Photos") {preview.lookup()}.disabled(preview.busy || WebsiteAddress.parse(preview.website)==nil)
                }
                Text("Reads public icons from the website. No email address or Contacts access is needed.").font(.caption).foregroundStyle(.secondary)
                if preview.busy {Text("Checking the website…").font(.caption).foregroundStyle(.tertiary)}
                if let result=preview.result {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:100,maximum:145),spacing:12)],spacing:12) {
                        ForEach(showAll ? result.candidates:CandidateSelection.recommended(result.candidates)) {candidate in
                            CandidateTile(candidate:candidate,selected:candidate.id==preview.selectedID,demo:false) {preview.selectedID=candidate.id}
                        }
                    }.padding(3)
                    if result.candidates.count>3 {Button(showAll ? "Show Less":"More Photos") {showAll.toggle()}.buttonStyle(.link)}
                    if let photo=preview.selected,let row=model.selected,!row.ignored {
                        Button("Use for \(row.displayName)") {model.addCandidate(photo,to:row.id)}.portraitAction(prominent:true)
                        Text("If automatic sync is enabled, this choice also updates Contacts.").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Sources") {SourceReportsView(reports:result.reports).padding(.top,12)}
                }
                if let error=preview.error {Text(error).foregroundStyle(.secondary)}
            }.padding(28).frame(maxWidth:640).frame(maxWidth:.infinity,alignment:.topLeading)
        }.onDisappear {preview.cancel()}
    }
}
