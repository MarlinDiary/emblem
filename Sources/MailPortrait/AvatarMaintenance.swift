import Foundation
import PortraitCore

extension AppModel {
    /// Analyze each distinct PNG once, off the UI actor. Candidate/source metadata
    /// is saved so subsequent selection and launch do not redo image analysis.
    func prepareAvatarQuality() async {
        guard !preparingAvatarQuality,launchError == nil else { return }
        preparingAvatarQuality=true
        defer { preparingAvatarQuality=false }
        let inputs=rows.flatMap(\.candidates).filter { $0.source.isBrand && $0.visualQuality == nil }
        let qualities=await Task.detached(priority:.utility) {
            var result:[String:AvatarVisualQuality]=[:]
            for c in inputs {
                if Task.isCancelled { break }
                let key=digest(c.png)
                if result[key] == nil { result[key]=ImagePipeline.visualQuality(of:c.png) }
            }
            return result
        }.value
        var replacement=rows,changed=Set<String>()
        for i in replacement.indices {
            guard !replacement[i].completed,!replacement[i].ignored,replacement[i].current?.image == nil else { continue }
            var candidates:[AvatarCandidate]=[]
            for var c in replacement[i].candidates {
                if c.visualQuality == nil,let q=qualities[digest(c.png)] { c.visualQuality=q;changed.insert(replacement[i].id) }
                if c.source.isBrand && !c.visuallyUsable {
                    if replacement[i].selectedCandidate == c.id { replacement[i].selectedCandidate=nil;replacement[i].selectionIsManual=false;replacement[i].lookupPolicy=nil }
                    changed.insert(replacement[i].id)
                } else { candidates.append(c) }
            }
            replacement[i].candidates=candidates
            if replacement[i].selectionIsManual != true {
                let best=CandidateSelection.automaticChoice(candidates)
                if replacement[i].selectedCandidate != best?.id {
                    replacement[i].selectedCandidate=best?.id;changed.insert(replacement[i].id)
                }
            }
        }
        if !changed.isEmpty { replaceRowsPreservingGrouping(replacement,changedIDs:changed);save() }
        // Generating a whole library of new type at once would monopolize the
        // main actor. Commit one current row at a time and yield between rows;
        // a user selection made while migrating must never be overwritten.
        var lettersChanged=false
        let ids=rows.filter { !$0.completed && !$0.ignored && $0.current?.image == nil && $0.candidates.contains { $0.origin.hasPrefix("local://monogram/v1/") } }.map(\.id)
        for id in ids {
            guard !Task.isCancelled else { break }
            guard let i=rows.firstIndex(where:{$0.id==id}),!rows[i].completed,!rows[i].ignored,rows[i].current?.image == nil else { continue }
            var current=rows
            for j in current[i].candidates.indices {
                let c=current[i].candidates[j]
                if c.source == .monogram,c.origin.hasPrefix("local://monogram/v1/"),
                   let v=Int(c.origin.split(separator:"/").last ?? "0"),let rendered=try? NameAvatar.candidate(name:current[i].name,variant:v) {
                    if current[i].selectedCandidate == c.id { current[i].selectedCandidate=rendered.id }
                    current[i].candidates[j]=rendered;lettersChanged=true
                }
            }
            replaceRowsPreservingGrouping(current,changedIDs:[id])
            await Task.yield()
        }
        if lettersChanged { save() }
    }
}


extension AppModel {
    /// A rendered cache is not an original. Repair changed canvas rules using
    /// the recorded public asset URL, never by cropping an already inset PNG.
    func refreshCanvasOriginals(client: any ResourceFetching = SafeWebClient()) async {
        guard useWebsite,!demo,launchError == nil else { return }
        var originals:[String:AvatarCandidate]=[:]
        for row in rows where !row.completed && !row.ignored && row.current?.image == nil {
            for c in row.candidates where c.source.isBrand && (c.layoutRevision ?? 0)<7 {
                if c.maskable == true || ((c.layoutRevision ?? 0)<6 && (c.artwork == .logo || (c.visualQuality?.frameFraction ?? 0)>0.01)) {
                    originals[c.origin]=c
                }
            }
        }
        let work=Array(originals.values).sorted { $0.origin<$1.origin }
        guard !work.isEmpty else { return }
        await withTaskGroup(of:(String,AvatarCandidate?).self) { group in
            var next=0
            func enqueue(_ c:AvatarCandidate) {
                group.addTask {
                    guard let url=URL(string:c.origin),NetworkPolicy.isAllowedURL(url) else { return (c.origin,nil) }
                    do {
                        let rendered=try await withDeadline(seconds:15) {
                            try ImagePipeline.decode(await client.fetch(url,limit:4_000_000),source:c.source,maskable:c.maskable == true,artwork:c.artwork)
                        }
                        return (c.origin,rendered)
                    } catch { return (c.origin,nil) }
                }
            }
            while next<min(3,work.count) { enqueue(work[next]);next+=1 }
            while let (origin,rendered)=await group.next() {
                if Task.isCancelled { group.cancelAll();break }
                if let rendered {
                    var replacement=rows,changed=Set<String>()
                    for i in replacement.indices where !replacement[i].completed && replacement[i].current?.image == nil {
                        for j in replacement[i].candidates.indices where replacement[i].candidates[j].origin == origin && (replacement[i].candidates[j].layoutRevision ?? 0)<7 {
                            let old=replacement[i].candidates[j]
                            var fresh=AvatarCandidate(source:old.source,origin:old.origin,width:rendered.width,height:rendered.height,vector:rendered.vector,png:rendered.png,maskable:rendered.maskable == true,framing:rendered.framing,subjectWidth:rendered.subjectWidth,subjectHeight:rendered.subjectHeight,layoutRevision:7,artwork:rendered.artwork,id:old.id)
                            fresh.visualQuality=rendered.visualQuality;fresh.declared=old.declared
                            replacement[i].candidates[j]=fresh;changed.insert(replacement[i].id)
                        }
                    }
                    if !changed.isEmpty { replaceRowsPreservingGrouping(replacement,changedIDs:changed);save() }
                }
                if next<work.count { enqueue(work[next]);next+=1 }
            }
        }
    }
}
