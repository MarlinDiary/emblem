import SwiftUI
import PortraitCore

struct BatchApplySheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let plan = model.batchPlan ?? BatchPlan(jobs: [], excluded: [])
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Apply Sender Photos").font(.title2.weight(.semibold))
                Text("\(plan.emailCount) addresses · \(plan.jobs.count) contacts")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 32) {
                metric("Update existing contacts", plan.updateCount)
                metric("Create new contacts", plan.newContactCount)
                if !plan.excluded.isEmpty { metric("Keep for review", plan.excluded.count) }
            }
            VStack(alignment: .leading, spacing: 12) {
                if plan.newContactCount > 0 {
                    Toggle("Create \(plan.newContactCount) contacts", isOn: $model.batchAllowCreate)
                    Text("New contacts are added to Contacts. iCloud syncs them to your other devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Group repeated brand addresses", isOn: $model.batchGroupBrands)
                Text("Only matching brand names, domains and photos are grouped. People and different existing contacts stay separate.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.toggleStyle(.checkbox)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plan.jobs) { job in
                        HStack(spacing: 12) {
                            PortraitAvatar(data: job.candidate.png, name: job.name, size: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(job.rows.count > 1 ? "\(job.rows.count) addresses · \(job.rows[0].email.domain)" : job.id)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(job.createsContact ? (model.batchAllowCreate ? "Create" : "Keep Unchanged") : "Update Photo")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 9).opacity(job.createsContact && !model.batchAllowCreate ? 0.5 : 1)
                        Divider()
                    }
                    if !plan.excluded.isEmpty {
                        DisclosureGroup("Skipped: \(plan.excluded.count) addresses") {
                            ForEach(plan.excluded) { issue in
                                LabeledContent(issue.id, value: issue.reason).font(.caption).padding(.vertical, 4)
                            }
                        }.padding(.top, 12)
                    }
                }.padding(.horizontal, 2)
            }.frame(height: 230)
            Text("Existing photos stay unchanged. Conflicts are skipped, and completed changes can be undone together.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { model.showBatchConfirmation = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply to \(model.batchEnabledJobs.count) Contacts") { model.confirmBatch() }
                    .portraitAction(prominent: true).keyboardShortcut(.defaultAction)
                    .disabled(model.batchEnabledJobs.isEmpty || model.busy)
            }
        }.padding(28).frame(width: 530)
    }
    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count, format: .number).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BatchProgressStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let progress = model.batchProgress {
            HStack(spacing: 14) {
                if !progress.finished { ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total))).frame(width: 100) }
                else { Image(systemName: progress.issues.isEmpty ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(.secondary) }
                Text(progress.title).font(.callout).monospacedDigit().lineLimit(1)
                Spacer()
                if !progress.finished {
                    Button("Stop") { model.cancel() }.help("Completed changes are kept. You can apply the remaining photos later.")
                } else {
                    if !progress.issues.isEmpty { Button("Review Issues") { model.showBatchIssues = true } }
                    if let id = progress.batchID, model.records.contains(where: { $0.batchID == id && $0.state == .applied }) { Button("Undo Batch…") { model.undoBatchID = id }.disabled(model.busy) }
                    Button { model.batchProgress = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss Result")
                }
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }
    }
}
struct BatchIssuesSheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("These Senders Need Attention").font(.title2.weight(.semibold))
            Text("Other senders were processed. These addresses remain in your library.") .foregroundStyle(.secondary).font(.callout)
            List(model.batchProgress?.issues ?? []) { issue in
                VStack(alignment: .leading, spacing: 5) {
                    Text(issue.id).font(.callout.weight(.medium)).textSelection(.enabled)
                    Text(issue.reason).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }.frame(height: 260)
            HStack {
                Button("Check Contacts Again") { model.showBatchIssues = false; model.connectContacts() }.disabled(model.busy)
                Spacer(); Button("Done") { model.showBatchIssues = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 510)
    }
}
