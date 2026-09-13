import SwiftUI
import PortraitCore

struct ImportSheet: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    private var count: Int { EmailAddress.parseList(model.importText).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(symbol: "person.crop.circle.badge.plus", title: "Add Senders", subtitle: "Paste email addresses to add them to your library. Automatic sync applies if enabled.")
            ZStack(alignment: .topLeading) {
                if model.importText.isEmpty { Text("Paste names and email addresses").foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 10).allowsHitTesting(false) }
                TextEditor(text: $model.importText).scrollContentBackground(.hidden).padding(4).focused($focused)
            }.font(.body).frame(height: 135).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
            HStack {
                Text(count == 0 ? "Up to 200 addresses at a time" : "\(count) addresses found\(count > 200 ? "; the first 200 will be added" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.showImport = false }.keyboardShortcut(.cancelAction)
                Button("Add") { model.importAddresses(model.importText, limit: 200); model.importText = ""; model.showImport = false }
                    .keyboardShortcut(.defaultAction).disabled(count == 0)
            }
        }.padding(28).frame(width: 470).onAppear { focused = true }
    }
}

struct SourceConsentSheet: View {
    @ObservedObject var model: AppModel
    @State private var website=true
    @State private var gravatar=false
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Photo Sources").font(.title2.weight(.semibold))
            Toggle("Websites and public profiles",isOn:$website)
            Toggle("Gravatar and Libravatar",isOn:$gravatar)
            Text("Websites receive lookup requests. Portrait services receive email hashes, which are not anonymous. You can change these choices in Settings.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") {model.showSourceConsent=false}.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.sourceSettingsOnly ? "Save":"Find Photos") {
                    model.useWebsite=website;model.useGravatar=gravatar;model.showSourceConsent=false
                    if model.sourceSettingsOnly {model.automaticTick()} else {model.lookup(ids:model.lookupIDs)}
                }.keyboardShortcut(.defaultAction).disabled(!website && !gravatar && !model.sourceSettingsOnly)
            }
        }.padding(28).frame(width:430)
            .onAppear {website=model.sourceSettingsOnly ? model.useWebsite:model.useWebsite || !model.useGravatar;gravatar=model.useGravatar}
    }
}

struct ApplySheet: View {
    @ObservedObject var model: AppModel
    private var rows: [SenderRow] { model.rows.filter { model.pendingIDs.contains($0.id) } }
    private var newCount: Int { rows.filter { $0.current == nil }.count }
    private var groupMode:Bool { model.pendingManagedGroupID != nil }
    private var uniqueContacts:Int { Set(rows.compactMap { $0.current?.id }).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(symbol: "person.crop.circle.badge.checkmark", title: groupMode ? "Use One Contact for These Addresses?" : model.demo ? "Apply to the Demo Library?" : "Apply These Photos?", subtitle: groupMode ? "\(rows.count) addresses share one contact and photo." : "Update \(rows.count) senders. Existing photos stay unchanged.")
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(groupMode ? Array(rows.prefix(1)) : rows) { row in
                        HStack(spacing: 12) {
                            PortraitAvatar(data: row.chosen?.png, name: row.name, size: 40)
                            VStack(alignment: .leading, spacing: 4) { Text(row.name).fontWeight(.medium); Text(row.email.value).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(groupMode ? "\(rows.count) addresses → 1 contact" : row.current == nil ? "New Contact" : "Update Photo").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(16)
            }.frame(height: min(CGFloat(rows.count) * 58 + 16, 210))
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            if groupMode {
                if uniqueContacts == 0 { Toggle("Create one new contact",isOn:$model.allowCreate).toggleStyle(.checkbox) }
                Toggle("Add future matching brand addresses to this contact",isOn:$model.manageFutureAliases).toggleStyle(.checkbox)
                Text("Only exact brand names and registered domains match. Similar names or unrelated domains are not merged.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if newCount > 0 {
                Toggle("Create contacts for \(newCount) new senders", isOn: $model.allowCreate).toggleStyle(.checkbox)
                Text("Create in: \(model.accountName)").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.demo ? "Demo mode changes only the separate test library." : "Changes are recorded before writing. iCloud syncs contact changes and deletions to your other devices.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.showApplyConfirmation = false }.keyboardShortcut(.cancelAction)
                Button(groupMode ? "Apply to One Contact" : "Apply Photo") { model.confirmApply() }.keyboardShortcut(.defaultAction)
                    .disabled(rows.isEmpty || (groupMode ? uniqueContacts == 0 && !model.allowCreate : newCount == rows.count && !model.allowCreate))
            }
        }.padding(28).frame(width: 460)
    }
}

struct ContactConsentSheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeading(symbol: "person.crop.circle.badge.checkmark", title: "Connect Contacts", subtitle: "Match existing contacts before updating photos or creating new cards.")
            VStack(alignment: .leading, spacing: 14) {
                Label("Existing photos are preserved", systemImage: "person.crop.circle")
                Label("Changes are recorded before writing", systemImage: "clock.arrow.circlepath")
                Label("Automatic sync follows your settings", systemImage: "checkmark.shield")
            }.font(.callout).padding(.vertical, 4)
            Text("macOS will request Contacts access. Photo previews remain available if you cancel.") .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Not Now") { model.showContactConsent = false }.keyboardShortcut(.cancelAction)
                Button("Continue") { model.showContactConsent = false; model.connectContacts(resumeApply: true) }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 430)
    }
}

struct SheetHeading: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Color.accentColor).frame(width: 42, height: 44)
            VStack(alignment: .leading, spacing: 7) { Text(title).font(.title2.weight(.semibold)); Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
