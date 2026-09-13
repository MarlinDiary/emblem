import AppKit
import SwiftUI
import PortraitCore

/// A source-list table that creates cells only for visible senders. AppModel has
/// many independent publishers (Gmail progress, source lookups, Contacts state);
/// those updates may call updateNSView, but do not reload sender cells unless the
/// row revision, filter, or batch presentation actually changed.
struct VirtualizedSenderTable:NSViewRepresentable {
    let model:AppModel
    let groups:[SenderGroup]
    let rowsRevision:UInt64
    let navigationKey:String
    let selectedGroupID:String?
    let batchMode:Bool
    let selectedForBatch:Set<String>
    let controlsDisabled:Bool

    func makeCoordinator()->Coordinator {Coordinator(model:model)}
    func makeNSView(context:Context)->NSScrollView {context.coordinator.makeScrollView()}
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        context.coordinator.update(
            scroll:scroll,groups:groups,rowsRevision:rowsRevision,
            navigationKey:navigationKey,selectedGroupID:selectedGroupID,
            batchMode:batchMode,selectedForBatch:selectedForBatch,
            controlsDisabled:controlsDisabled
        )
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {coordinator.stopObserving()}

    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        struct RenderSignature:Equatable {
            let rowsRevision:UInt64
            let navigationKey:String
            let batchMode:Bool
            let selectedForBatch:Set<String>
            let controlsDisabled:Bool
        }
        let model:AppModel
        let table=SenderNativeTableView()
        var groups:[SenderGroup]=[]
        var signature:RenderSignature?
        var selectedForBatch=Set<String>()
        var batchMode=false
        var controlsDisabled=false
        var currentNavigationKey:String?
        var boundsObserver:NSObjectProtocol?
        var updatingSelection=false
        var generatedImages:[String:NSImage]=[:]
        private(set) var fullReloadCount=0
        private(set) var configuredCellCount=0

        init(model:AppModel) {self.model=model;super.init()}

        func makeScrollView()->NSScrollView {
            let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("sender"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView=nil
            table.rowHeight=62
            table.intercellSpacing = .zero
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .regular
            table.style = .sourceList
            table.allowsEmptySelection=true
            table.allowsMultipleSelection=false
            table.dataSource=self;table.delegate=self
            table.contextMenuForRow={ [weak self] row in self?.contextMenu(row:row) }

            let scroll=NSScrollView()
            scroll.documentView=table
            scroll.drawsBackground=false
            scroll.hasVerticalScroller=true
            scroll.autohidesScrollers=true
            scroll.contentView.postsBoundsChangedNotifications=true
            boundsObserver=NotificationCenter.default.addObserver(
                forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main
            ) { [weak self,weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self,let scroll,let key=self.currentNavigationKey else{return}
                    self.model.navigationMemory.offsets[key]=scroll.contentView.bounds.minY
                }
            }
            return scroll
        }

        func stopObserving() {
            if let boundsObserver {NotificationCenter.default.removeObserver(boundsObserver)}
            boundsObserver=nil
        }

        func update(scroll:NSScrollView,groups:[SenderGroup],rowsRevision:UInt64,
                    navigationKey:String,selectedGroupID:String?,batchMode:Bool,
                    selectedForBatch:Set<String>,controlsDisabled:Bool) {
            let next=RenderSignature(rowsRevision:rowsRevision,navigationKey:navigationKey,
                                     batchMode:batchMode,selectedForBatch:selectedForBatch,
                                     controlsDisabled:controlsDisabled)
            let shouldReload=signature != next
            let oldKey=currentNavigationKey
            if oldKey != navigationKey,let oldKey {
                model.navigationMemory.offsets[oldKey]=scroll.contentView.bounds.minY
            }
            self.groups=groups
            self.batchMode=batchMode
            self.selectedForBatch=selectedForBatch
            self.controlsDisabled=controlsDisabled
            self.currentNavigationKey=navigationKey
            if shouldReload {
                signature=next;fullReloadCount += 1
                table.reloadData()
                table.sizeLastColumnToFit()
                if oldKey != navigationKey {
                    table.layoutSubtreeIfNeeded()
                    let maximum=max(0,(scroll.documentView?.frame.height ?? 0)-scroll.contentView.bounds.height)
                    let target=min(maximum,max(0,model.navigationMemory.offsets[navigationKey] ?? 0))
                    scroll.contentView.scroll(to:NSPoint(x:0,y:target))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            updateSelection(selectedGroupID)
        }

        func numberOfRows(in tableView:NSTableView)->Int {groups.count}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard groups.indices.contains(row) else{return nil}
            configuredCellCount += 1
            let identifier=NSUserInterfaceItemIdentifier(batchMode ? "sender.batch" : "sender.normal")
            let cell=(tableView.makeView(withIdentifier:identifier,owner:nil) as? SenderNativeCell)
                ?? SenderNativeCell(identifier:identifier,batchMode:batchMode)
            let group=groups[row],representative=group.representative
            cell.configure(
                group:group,image:image(for:group),batchSelected:group.emailIDs.isSubset(of:selectedForBatch),
                controlsDisabled:controlsDisabled,row:row,target:self
            )
            cell.toolTip=representative.email.value
            return cell
        }

        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !updatingSelection,groups.indices.contains(table.selectedRow) else{return}
            model.selectedListID=groups[table.selectedRow].id
        }

        private func updateSelection(_ groupID:String?) {
            let index=groupID.flatMap { id in groups.firstIndex(where:{$0.id==id}) }
            let desired=index.map {IndexSet(integer:$0)} ?? IndexSet()
            guard table.selectedRowIndexes != desired else{return}
            updatingSelection=true
            table.selectRowIndexes(desired,byExtendingSelection:false)
            updatingSelection=false
        }

        private func image(for group:SenderGroup)->NSImage? {
            if let data=group.avatar {return PortraitImageCache.shared.image(for:data,pixelSize:76)}
            let name=group.representative.displayName
            if let cached=generatedImages[name] {return cached}
            guard let candidate=try? NameAvatar.candidate(name:name),
                  let image=PortraitImageCache.shared.image(for:candidate.png,pixelSize:76) else{return nil}
            if generatedImages.count>128 {generatedImages.removeAll(keepingCapacity:true)}
            generatedImages[name]=image
            return image
        }

        @objc func toggleBatch(_ sender:NSButton) {
            guard groups.indices.contains(sender.tag) else{return}
            model.selectGroup(groups[sender.tag],enabled:sender.state == .on)
        }
        private func group(from item:NSMenuItem)->SenderGroup? {
            guard let id=item.representedObject as? String else{return nil}
            return groups.first(where:{$0.id==id})
        }
        @objc func beginBatch(_ item:NSMenuItem) {
            guard let group=group(from:item) else{return}
            model.batchMode=true;model.selectGroup(group,enabled:true)
        }
        @objc func findAgain(_ item:NSMenuItem) {
            guard let group=group(from:item) else{return}
            model.requestLookup(ids:group.members.map(\.id))
        }
        @objc func toggleIgnored(_ item:NSMenuItem) {
            guard let group=group(from:item) else{return}
            if group.representative.ignored {model.restoreIgnored(group.emailIDs)}
            else {Task { @MainActor in
                do {try await model.ignoreSyncedSenders(group.emailIDs)}
                catch {model.errorText=error.localizedDescription}
            }}
        }
        private func contextMenu(row:Int)->NSMenu? {
            guard groups.indices.contains(row) else{return nil}
            let group=groups[row],representative=group.representative,menu=NSMenu()
            func item(_ title:String,_ action:Selector,enabled:Bool=true)->NSMenuItem {
                let result=NSMenuItem(title:title,action:action,keyEquivalent:"")
                result.target=self;result.representedObject=group.id;result.isEnabled=enabled;return result
            }
            menu.addItem(item("Select Multiple Senders",#selector(beginBatch(_:)),enabled:!controlsDisabled))
            menu.addItem(item("Find Again",#selector(findAgain(_:)),enabled:!controlsDisabled && !representative.ignored))
            menu.addItem(.separator())
            menu.addItem(item(representative.ignored ? "Restore Sender" : "Ignore Sender",#selector(toggleIgnored(_:)),enabled:!controlsDisabled))
            return menu
        }
    }
}

@MainActor final class SenderNativeTableView:NSTableView {
    var contextMenuForRow:((Int)->NSMenu?)?
    override func menu(for event:NSEvent)->NSMenu? {
        let point=convert(event.locationInWindow,from:nil),index=row(at:point)
        guard index>=0 else{return super.menu(for:event)}
        selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
        return contextMenuForRow?(index)
    }
}

@MainActor final class SenderNativeCell:NSTableCellView {
    let checkbox:NSButton
    let avatar=NSImageView()
    let titleLabel=NSTextField(labelWithString:"")
    let subtitleLabel=NSTextField(labelWithString:"")

    init(identifier:NSUserInterfaceItemIdentifier,batchMode:Bool) {
        checkbox=NSButton(checkboxWithTitle:"",target:nil,action:nil)
        super.init(frame:.zero);self.identifier=identifier
        avatar.translatesAutoresizingMaskIntoConstraints=false
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer=true;avatar.layer?.cornerRadius=19;avatar.layer?.masksToBounds=true
        titleLabel.font = .systemFont(ofSize:13,weight:.medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize:11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let labels=NSStackView(views:[titleLabel,subtitleLabel])
        labels.orientation = .vertical;labels.alignment = .leading;labels.spacing=4
        labels.setHuggingPriority(.defaultLow,for:.horizontal)
        let views=batchMode ? [checkbox,avatar,labels] : [avatar,labels]
        let row=NSStackView(views:views)
        row.orientation = .horizontal;row.alignment = .centerY;row.spacing=11
        row.translatesAutoresizingMaskIntoConstraints=false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),
            row.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8),
            row.centerYAnchor.constraint(equalTo:centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant:38),avatar.heightAnchor.constraint(equalToConstant:38),
        ])
        titleLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    }
    required init?(coder:NSCoder) {fatalError()}

    func configure(group:SenderGroup,image:NSImage?,batchSelected:Bool,
                   controlsDisabled:Bool,row:Int,target:VirtualizedSenderTable.Coordinator) {
        let representative=group.representative
        avatar.image=image ?? NSImage(systemSymbolName:"person.crop.circle",accessibilityDescription:nil)
        avatar.contentTintColor=image == nil ? .secondaryLabelColor : nil
        titleLabel.stringValue=representative.displayName
        subtitleLabel.stringValue=group.members.count>1
            ? "\(DomainRouting.primaryHost(for:representative.email.domain)) · \(group.members.count) addresses"
            : representative.email.value
        checkbox.tag=row;checkbox.state=batchSelected ? .on:.off
        checkbox.isEnabled = !controlsDisabled
        checkbox.target=target;checkbox.action=#selector(VirtualizedSenderTable.Coordinator.toggleBatch(_:))
        checkbox.setAccessibilityLabel("Select \(representative.displayName)")
    }
}
