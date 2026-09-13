import SwiftUI
import AppKit
import PortraitCore

struct SenderList: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let groups = model.visibleGroups
        return VStack(spacing: 0) {
            if groups.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "No Senders" : "No Results", systemImage: model.search.isEmpty ? "person.crop.circle" : "magnifyingglass", description: Text(model.search.isEmpty ? emptyDescription : "Try another name or email address."))
                    .frame(maxHeight: .infinity)
            } else {
                // AppKit asks for only the rows that are actually visible. The
                // former SwiftUI ForEach rebuilt hundreds of row/context-menu
                // trees whenever any AppModel publisher changed.
                VirtualizedSenderTable(
                    model:model,groups:groups,rowsRevision:model.rowsRevision,
                    navigationKey:model.navigationKey,selectedGroupID:model.selectedListID,
                    batchMode:model.batchMode,selectedForBatch:model.batchMode ? model.selectedForBatch : [],
                    controlsDisabled:model.busy || model.isScanning
                )
            }
            if model.batchMode {
                HStack {
                    Button(model.selectedForBatch.count == model.visibleEmailCount ? "Deselect All" : "Select All") {
                        if model.selectedForBatch.count == model.visibleEmailCount { model.selectedForBatch.removeAll() }
                        else { model.selectedForBatch=Set(model.visibleRows.map(\.id)) }
                    }.buttonStyle(.borderless).keyboardShortcut("a")
                    Spacer()
                }.controlSize(.small).padding(12)
            }
        }.background {SidebarMaterial().ignoresSafeArea(edges:.top)}
    }
    private var emptyDescription: String {
        switch model.section {
        case "completed": return "Applied photos appear here."
        case "existing": return "Contacts with existing photos appear here. Their photos are preserved."
        case "ignored": return "Ignored senders appear here."
        case "ready": return "Ready photos can be applied together."
        case "review": return "Senders still needing a photo appear here."
        case "pending": return model.rows.isEmpty ? "Connect an account to discover senders." : "No senders are waiting for a photo."
        default: return "Connect an account or add a sender."
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: AppSession
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 62, weight: .ultraLight)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text(model.rows.isEmpty ? "Put a Face to Your Inbox" : "Select a Sender").font(.title2.weight(.semibold))
                Text(model.rows.isEmpty ? "Recognize familiar people and brands at a glance." : "Choose a photo for a familiar name.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if model.rows.isEmpty {
                if !model.automation.setupComplete {
                    Button("Enable Automatic Sync") { model.showSyncSetup = true }.portraitAction(prominent:true).controlSize(.large)
                } else if !model.mailSync.enabled { Button("Enable Automatic Sync") {model.showSyncSetup=true}.portraitAction(prominent:true) }
                Text("Automatic sync keeps sender photos up to date in Contacts.") .font(.caption).foregroundStyle(.tertiary)
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SenderDetail: View {
    @ObservedObject var model: AppModel
    let row: SenderRow
    @State private var showEmails = false
    @State private var showAllCandidates = false
    private var pendingChoice:Bool {model.mailSync.explicitChoices[MailSyncIdentity.key(row)]==row.id}
    private var editable: Bool { !row.ignored && (model.mailSync.enabled || (!row.completed && row.current?.image == nil)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                identity
                if editable {
                    if let issue = row.applicationIssue {
                        Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    }
                    candidates
                }
                if model.demo { Text("Demo Library").font(.caption).foregroundStyle(.tertiary) }
            }.frame(maxWidth: 560, alignment: .leading).padding(24).frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollClipDisabled()
        .safeAreaInset(edge: .bottom) { if row.ignored { actions.padding(.horizontal, 24).padding(.vertical, 16) } }
    }
    private var identity: some View {
        HStack(spacing: 16) {
            PortraitAvatar(data: pendingChoice ? row.chosen?.png : row.current?.image ?? row.chosen?.png, name: row.displayName, size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(row.displayName).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                if let group = model.selectedGroup, group.members.count > 1 {
                    Button("\(group.members.count) addresses") { showEmails.toggle() }
                        .buttonStyle(.link).font(.callout)
                        .popover(isPresented:$showEmails) {
                            ScrollView {
                                VStack(alignment:.leading,spacing:12) {
                                    ForEach(group.members) { Text($0.email.value).textSelection(.enabled) }
                                }.font(.callout).padding(20)
                            }.frame(width:340,height:min(320,CGFloat(group.members.count)*32+40))
                        }
                } else { Text(row.email.value).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }

            }
            Spacer(minLength: 0)
        }
    }
    @ViewBuilder private var actions: some View {
        if row.ignored {
            Button("Restore Sender") { model.restoreIgnored(model.selectedGroup?.emailIDs ?? [row.id]); model.section = "all" }.portraitAction().disabled(model.busy)

        }
    }
    private var candidates: some View {
        let currentID=model.currentAvatarSource(for:row)?.id
        return VStack(alignment: .leading, spacing: 14) {
            if row.candidates.filter({ $0.source != .monogram }).count > 3 {
                Button(showAllCandidates ? "Show Less" : "More Photos") {showAllCandidates.toggle()}.buttonStyle(.link).font(.caption)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 94, maximum: 144), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(model.avatarChoices(for: row, allSizes: showAllCandidates)) { candidate in
                    CandidateTile(candidate: candidate, selected: pendingChoice ? candidate.id == row.selectedCandidate : currentID.map {$0 == candidate.id} ?? row.current?.image.map { $0 == candidate.png } ?? (candidate.id == row.selectedCandidate), demo: model.demo) {
                        model.addCandidate(candidate, to: row.id)
                    }.disabled(model.busy)
                }
                PhotoUploadTile {model.chooseFile()}.disabled(model.busy)
            }.padding(3)
        }
    }
}

struct CandidateTile: View {
    let candidate: AvatarCandidate
    let selected: Bool
    let demo: Bool
    var action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                PortraitAvatar(data: candidate.png, size: 64)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }.frame(maxWidth: .infinity).frame(height: 116)
                .background(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                // Stroke stays entirely inside the tile; reserve grid padding
                // separately so neither selection nor keyboard focus is clipped.
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : focused ? Color.primary : Color(nsColor: .separatorColor).opacity(0.45), lineWidth: selected || focused ? 2 : 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).focused($focused).focusEffectDisabled()
            .accessibilityLabel(candidate.source == .monogram ? "Monogram, generated on this Mac" : "\(title), \(candidate.vector ? "Vector" : "\(candidate.width) × \(candidate.height)")")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var title: String {
        if candidate.origin.hasPrefix("contacts://") {return "Current Photo"}
        if demo && candidate.origin.hasPrefix("demo:") { return "Demo Icon" }
        switch candidate.source { case .gravatar: return "Gravatar"; case .libravatar: return "Libravatar"; case .profile: return "Public Profile"; case .institutionProfile: return "Public Profile"; case .officialBrand: return "Official Brand"; case .bimi: return "BIMI"; case .siteLogo: return "Website Logo"; case .touchIcon: return "Touch Icon"; case .manifest: return candidate.maskable == true ? "Adaptive Icon" : "Web App Icon"; case .favicon: return "Website Icon"; case .domainIcon: return "Domain Icon"; case .monogram: return "Monogram"; case .manual: return "Your Photo" }
    }
}

struct PortraitAvatar: View {
    let data: Data?
    var name = ""
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Group {
            if let data, let image = PortraitImageCache.shared.image(for: data, pixelSize:Int(ceil(size*displayScale))) { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else if !name.isEmpty, let avatar = try? NameAvatar.candidate(name: name), let image = PortraitImageCache.shared.image(for: avatar.png,pixelSize:Int(ceil(size*displayScale))) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Circle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                    .overlay { if name.isEmpty { Image(systemName: "person.fill").font(.system(size: size * 0.42, weight: .light)).foregroundStyle(.secondary) } else { Text(initials).font(.system(size: size * 0.35, weight: .medium)).foregroundStyle(.secondary) } }
            }
        }.frame(width: size, height: size).clipShape(Circle())
            .accessibilityHidden(true)
    }
    private var initials: String {
        let parts = name.split(separator: " ")
        if parts.count > 1 { return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(name.prefix(1)).uppercased()
    }
}

struct PhotoUploadTile:View {
    var action:()->Void
    var body:some View {
        Button(action:action) {
            VStack(spacing:10) {
                Image(systemName:"photo.badge.plus").font(.system(size:27,weight:.light)).foregroundStyle(.secondary).frame(height:64)
                Text("Choose Photo").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity).frame(height:116)
                .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14))
                .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(Color(nsColor:.separatorColor).opacity(0.45),lineWidth:0.5))
        }.buttonStyle(.plain).accessibilityLabel("Choose a Photo")
    }
}

/// Explicit geometry: an unconstrained SwiftUI Divider defaults to horizontal.
/// Only the column boundary should span the sidebar, never its middle row.
struct SidebarBoundary:View {
    @Environment(\.displayScale) private var displayScale
    var body:some View {
        Rectangle().fill(Color(nsColor:.separatorColor))
            .frame(width:1/max(displayScale,1)).frame(maxHeight:.infinity)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// AppKit's semantic sidebar material supplies light/dark and accessibility
/// behavior; the sender list keeps native continuous scrolling and separators.
struct SidebarMaterial:NSViewRepresentable {
    func makeNSView(context:Context)->NSVisualEffectView {
        let view=NSVisualEffectView();view.material = .sidebar;view.blendingMode = .behindWindow;view.state = .followsWindowActiveState;return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {}
}
