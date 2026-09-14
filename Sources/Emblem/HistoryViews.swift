import SwiftUI
import PortraitCore

struct HistoryList: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if model.visibleRecords.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "No Changes Yet" : "No Results", systemImage: model.search.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass", description: Text(model.search.isEmpty ? "Applied changes and undo options appear here." : "Try another name or email address."))
            } else {
                List(selection: $model.selectedHistoryID) {
                    if let id = model.latestBatchID {
                        Section {
                            Button("Undo Last Batch…", systemImage: "arrow.uturn.backward") { model.undoBatchID = id }.disabled(model.busy)
                        }
                    }
                    ForEach(model.visibleRecords.reversed()) { record in
                        HStack(spacing: 11) {
                            Image(systemName: record.state == .undone ? "arrow.uturn.backward.circle" : record.state == .prepared ? "exclamationmark.circle" : "checkmark.circle")
                                .font(.title3).foregroundStyle(record.state == .prepared ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.rows.first { $0.id == record.email }?.name ?? record.email).font(.callout.weight(.medium)).lineLimit(1)
                                Text(record.state == .undone ? "Undone" : record.state == .prepared ? "Needs Review" : record.created ? "Contact Created" : "Photo Updated")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(record.date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }.padding(.vertical, 7).tag(record.id)
                    }
                }.listStyle(.inset).portraitScrollTop()
            }
        }.portraitScrollTop().onAppear { if model.selectedHistoryID == nil { model.selectedHistoryID = model.records.last?.id } }
    }
}

struct HistoryDetail: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let record = model.selectedHistory {
            ScrollView {
                VStack(spacing: 26) {
                    Image(systemName: record.state == .undone ? "checkmark.circle" : "clock.arrow.circlepath")
                        .font(.system(size: 52, weight: .light)).foregroundStyle(record.state == .undone ? .green : .secondary)
                    VStack(spacing: 8) {
                        Text(record.state == .undone ? "Change Undone" : record.state == .prepared ? "Review This Change" : record.created ? "Contact Created" : "Photo Updated").font(.title2.weight(.semibold))
                        Text(record.email).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    VStack(spacing: 0) {
                        row("Date", record.date.formatted(date: .abbreviated, time: .shortened))
                        Divider().padding(.leading, 14)
                        row("Change", record.created ? "Create contact and photo" : "Update existing contact photo")
                        Divider().padding(.leading, 14)
                        row("Status", record.state == .undone ? "Undone" : record.state == .prepared ? "Needs Review" : "Completed")
                    }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    if record.state == .applied {
                        if let batchID = record.batchID {
                            Button("Undo This Batch…") { model.undoBatchID = batchID }.disabled(model.busy)
                        }
                        VStack(spacing: 14) {
                            Button(record.created ? "Delete Created Contact…" : "Undo Photo Change…", role: record.created ? .destructive : nil) { model.undoRecord = record }
                                .controlSize(.large).disabled(model.busy)
                            Text(record.created ? "Only unchanged contacts created by this app are deleted. Later edits are preserved." : "Restore the previous photo and keep the contact and its other details.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    } else if record.state == .prepared {
                        Text("The last write may have been interrupted. Check this address in Contacts before trying again.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Contacts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Contacts.app")) }
                    }
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(record.detail)
                            Text(record.source).textSelection(.enabled)
                            Text("Change ID: \(record.id.uuidString)").textSelection(.enabled)
                            Button("Show Backup Folder") { NSWorkspace.shared.open(model.root) }
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                    }.font(.callout)
                }.frame(maxWidth: 440).padding(36).frame(maxWidth: .infinity)
            }.portraitScrollTop()
        } else {
            ContentUnavailableView("Your Changes, Kept Locally", systemImage: "clock.arrow.circlepath", description: Text("Backups and undo options appear here after you apply a photo."))
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value) }.font(.callout).padding(14)
    }
}
