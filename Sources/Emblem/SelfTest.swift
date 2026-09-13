import Foundation
import AppKit
import PortraitCore

@MainActor enum SelfTest {
    static func run(arguments: [String]) -> Int32 {
        do {
            guard let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count else { throw PortraitError.message("--self-test requires --data-dir PATH (isolated fixture files only)") }
            let parent = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            let root = parent.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("Emblem isolated fixture v1\n".utf8).write(to: root.appendingPathComponent("fixture.marker"))
            let storeURL = root.appendingPathComponent("fixture-contacts.json"), journalURL = root.appendingPathComponent("changes.json")
            let store = try FixtureContactStore(url: storeURL)
            let email = EmailAddress("existing@example.org")!, newEmail = EmailAddress("created@example.org")!
            store.contacts["baseline-contact"] = .init(id: "baseline-contact", name: "Fixture Existing", emails: [email.value], image: nil)
            let journal = FileJournal(url: journalURL), engine = ChangeEngine(store: store, journal: journal)
            let candidate = try DemoImages.candidate(symbol: "person.crop.square", color: .systemIndigo)
            let first = try engine.apply(email: email, name: "Ignored Name", candidate: candidate, allowCreate: false)
            guard store.contacts.count == 1, store.contacts["baseline-contact"]?.image != nil, store.contacts["baseline-contact"]?.name == "Fixture Existing" else { throw PortraitError.message("existing contact update failed") }
            print("PASS existing-contact: photo updated, name and contact count preserved")
            let reopened = try FixtureContactStore(url: storeURL)
            guard reopened.contacts["baseline-contact"]?.image == store.contacts["baseline-contact"]?.image else { throw PortraitError.message("persistence failed") }
            print("PASS restart: saved photo read back from disk")
            try engine.undo(id: first.id)
            guard store.contacts["baseline-contact"]?.image == nil else { throw PortraitError.message("photo undo failed") }
            print("PASS undo-existing: photo restored, existing contact retained")
            let second = try engine.apply(email: newEmail, name: "Fixture New", candidate: candidate, allowCreate: true)
            guard store.contacts.count == 2 else { throw PortraitError.message("create failed") }
            store.externalRevision = 1
            do { try engine.undo(id: second.id); throw PortraitError.message("deletion guard failed") }
            catch { guard store.contacts.count == 2 else { throw error } }
            print("PASS deletion-guard: external edits prevent contact deletion")
            store.externalRevision = 0
            try engine.undo(id: second.id)
            guard store.contacts.count == 1 else { throw PortraitError.message("created contact cleanup failed") }
            print("PASS undo-created: only app-created contact deleted")
            let alias1=EmailAddress("code-1@fixture.org")!,alias2=EmailAddress("code-2@fixture.org")!
            let grouped=try engine.applyGroup(emails:[email,alias1],name:"Fixture Organization",candidate:candidate,allowCreate:false,managedKey:"fixture organization|fixture.org")
            guard store.contacts.count == 1,Set(store.contacts["baseline-contact"]?.emails ?? []) == Set([email.value,alias1.value]) else { throw PortraitError.message("grouped aliases did not share one contact") }
            let appended=try engine.appendManagedAliases(contactID:"baseline-contact",emails:[alias2],managedKey:"fixture organization|fixture.org")
            guard appended != nil,store.contacts.count == 1,store.contacts["baseline-contact"]?.emails.count == 3 else { throw PortraitError.message("future alias append failed") }
            try engine.undo(id:appended!.id);try engine.undo(id:grouped.id)
            guard store.contacts["baseline-contact"]?.emails == [email.value],store.contacts["baseline-contact"]?.image == nil else { throw PortraitError.message("grouped alias rollback failed") }
            print("PASS managed-aliases: one card accepted future alias; reverse-order undo restored email list and photo")
            let sampleSVG = ##"<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180" viewBox="0 0 180 180"><rect width="180" height="180" fill="#5470ce"/><circle cx="90" cy="90" r="40" fill="#ffffff"/></svg>"##
            let vector = try ImagePipeline.decode(.init(data: Data(sampleSVG.utf8), url: URL(string: "https://fixture.org/icon.svg")!), source: .touchIcon)
            guard vector.vector, NSImage(data: vector.png) != nil else { throw PortraitError.message("SVG to PNG failed") }
            print("PASS icon: standalone SVG rendered to PNG")
            let listModel = AppModel(demo: true, rootOverride: root.appendingPathComponent("list-lifecycle"))
            listModel.loadDemo()
            guard let row = listModel.rows.first, let preview = row.chosen else { throw PortraitError.message("demo list failed") }
            let listRecord = try listModel.engine.apply(email: row.email, name: row.name, candidate: preview, allowCreate: true)
            let beforeJournal = try Data(contentsOf: listModel.root.appendingPathComponent("changes.json"))
            listModel.ignore(row.id, ignored: true)
            guard listModel.rows.first?.ignored == true else { throw PortraitError.message("ignore failed") }
            listModel.removeFromList(row.id)
            guard !listModel.rows.contains(where: { $0.id == row.id }),
                  try listModel.port.get(id: listRecord.contactID!) != nil,
                  try Data(contentsOf: listModel.root.appendingPathComponent("changes.json")) == beforeJournal else { throw PortraitError.message("list removal changed contacts or journal") }
            let restoredModel = AppModel(demo: true, rootOverride: listModel.root)
            guard !restoredModel.rows.contains(where: { $0.id == row.id }), restoredModel.records.count == 1 else { throw PortraitError.message("list persistence failed") }
            try restoredModel.engine.undo(id: listRecord.id)
            guard try restoredModel.port.get(id: listRecord.contactID!) == nil else { throw PortraitError.message("undo after list removal failed") }
            print("PASS list-removal: ignore/remove/restart preserve Contacts and journal; undo still available")
            // Leave a new, explicitly isolated fixture application for runnable rollback verification.
            _ = try engine.apply(email: email, name: "Fixture", candidate: candidate, allowCreate: false)
            _ = try engine.apply(email: newEmail, name: "Fixture", candidate: candidate, allowCreate: true)
            print("ROLLBACK_FIXTURE=\(root.path)")
            print("REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0 MAIL_MESSAGES_READ=0")
            return 0
        } catch { print("FAIL \(error.localizedDescription)"); return 1 }
    }
    static func rollback(arguments: [String]) -> Int32 {
        do {
            guard let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count else { throw PortraitError.message("--rollback-fixture requires --data-dir PATH") }
            let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            guard try String(contentsOf: root.appendingPathComponent("fixture.marker"), encoding: .utf8) == "Emblem isolated fixture v1\n" else { throw PortraitError.message("not a Emblem fixture") }
            let store = try FixtureContactStore(url: root.appendingPathComponent("fixture-contacts.json"))
            let engine = ChangeEngine(store: store, journal: FileJournal(url: root.appendingPathComponent("changes.json")))
            for record in try engine.records().reversed() where record.state == .applied { try engine.undo(id: record.id) }
            guard store.contacts.count == 1, store.contacts["baseline-contact"]?.image == nil else { throw PortraitError.message("rollback baseline mismatch") }
            print("PASS rollback: baseline contact restored; created contacts removed")
            print("REAL_CONTACTS_WRITTEN=0")
            return 0
        } catch { print("FAIL \(error.localizedDescription)"); return 1 }
    }
}

@MainActor enum LiveIconSmoke {
    static func run() {
        Task {
            do {
                // Public website metadata only: no personal address, no Gravatar, no Contacts access.
                let result = try await AvatarResolver().resolve(email: EmailAddress("icon-test@github.com")!, gravatar: false, website: true)
                for candidate in result.candidates { print("ICON \(candidate.source.rawValue) \(candidate.width)x\(candidate.height) vector=\(candidate.vector) PNG_BYTES=\(candidate.png.count)") }
                guard result.candidates.contains(where: { $0.vector || min($0.width, $0.height) >= 128 }) else { throw PortraitError.message("no high-resolution website icon: \(result.notes.joined(separator: "; "))") }
                print("PASS live HTTPS icon lookup; no Contacts or Mail access"); exit(0)
            } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }
}

@MainActor enum LiveSourcesSmoke {
    static func run() {
        Task {
            do {
                for host in ["github.com","www.apple.com"] {
                    let result=try await AvatarResolver().resolveWebsite(at:URL(string:"https://"+host+"/")!)
                    for image in result.candidates {
                        print("SOURCE domain=\(host) type=\(image.source.rawValue) width=\(image.width) height=\(image.height) vector=\(image.vector) png=\(image.png.count)")
                    }
                    guard result.candidates.contains(where:{ !$0.lowResolution }) else { throw PortraitError.message("No high resolution icon at \(host)") }
                    print("PASS website=\(host) candidates=\(result.candidates.count) recommended=\(CandidateSelection.recommended(result.candidates).count)")
                }
                // Published example hash from https://docs.gravatar.com/sdk/images/.
                // Never derives a hash from the user's contacts or private email.
                let url=URL(string:"https://gravatar.com/avatar/27205e5c51cb03f862138b22bcb5dc20f94a342e744ff6df1b8dc8af3c865109?s=512&d=404&r=g")!
                let image=try ImagePipeline.decode(await SafeWebClient().fetch(url,limit:4_000_000),source:.gravatar)
                guard !image.lowResolution else { throw PortraitError.message("Public Gravatar example is low resolution") }
                print("PASS gravatar=published-documentation-example width=\(image.width) height=\(image.height)")
                print("REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0 MAIL_MESSAGES_READ=0 PRIVATE_EMAIL_HASHES_SENT=0")
                exit(0)
            } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }
}

@MainActor enum LiveProfileBrandSmoke {
    static func run(arguments: [String]) {
        Task {
            do {
                guard let index = arguments.firstIndex(of: "--output-dir"), index + 1 < arguments.count else {
                    throw PortraitError.message("--live-profile-brand-smoke requires --output-dir PATH")
                }
                let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

                let resolver = AvatarResolver()
                let people = [
                    ("valerio-terragni", "v.terragni@auckland.ac.nz", "Valerio Terragni"),
                    ("carmen-carmona-aragon", "carmen.carmona.aragon@auckland.ac.nz", "Carmen Carmona Aragon"),
                    ("elliott-wen", "elliott.wen@auckland.ac.nz", "Elliott Wen"),
                    ("karren-maltseva", "k.maltseva@auckland.ac.nz", "Karren Maltseva")
                ]
                for (file, address, name) in people {
                    let result = try await resolver.resolve(email: EmailAddress(address)!, displayName: name, gravatar: false, website: true)
                    guard let image = result.candidates.first(where: { $0.source == .institutionProfile }), NSImage(data: image.png) != nil else {
                        throw PortraitError.message("missing exact institutional portrait: \(name)")
                    }
                    let path = output.appendingPathComponent(file + ".png")
                    try image.png.write(to: path, options: .atomic)
                    print("PASS profile name=\(name) source=\(image.source.rawValue) original=\(image.width)x\(image.height) output=\(path.path)")
                }
                for (file, host) in [("raycast", "raycast.com"), ("adidas", "adidas.com"), ("linkedin", "linkedin.com")] {
                    let result = try await resolver.resolveWebsite(at: URL(string: "https://\(host)")!)
                    guard let image = result.candidates.first(where: { $0.source == .officialBrand }), NSImage(data: image.png) != nil else {
                        throw PortraitError.message("missing official brand asset: \(host)")
                    }
                    let path = output.appendingPathComponent(file + ".png")
                    try image.png.write(to: path, options: .atomic)
                    print("PASS brand domain=\(host) source=\(image.source.rawValue) original=\(image.width)x\(image.height) subject=\(image.subjectWidth ?? image.width)x\(image.subjectHeight ?? image.height) framing=\(image.effectiveFraming.rawValue) output=\(path.path)")
                }
                print("REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0 MAIL_MESSAGES_READ=0 FULL_EMAILS_SENT=0 DISPLAY_NAMES_SENT_TO_INSTITUTION=4")
                exit(0)
            } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }
}

/// Live, public-web-only acceptance for the exact v0.9.1 regressions reported by
/// users. It never opens Mail or Contacts and writes only rendered public assets
/// to the explicitly supplied output directory.
@MainActor enum LiveV091Smoke {
    private struct Case {
        let file: String
        let address: String
        let name: String
        let expectedFraming: AvatarFraming?
        let expectedSource: CandidateSource?
    }

    static func run(arguments: [String]) {
        Task {
            do {
                guard let index = arguments.firstIndex(of: "--output-dir"), index + 1 < arguments.count else {
                    throw PortraitError.message("--live-v091-smoke requires --output-dir PATH")
                }
                let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

                let resolver = AvatarResolver()
                let cases = [
                    Case(file: "linkedin-invitations", address: "invitations@linkedin.com", name: "LinkedIn", expectedFraming: .brandCanvas, expectedSource: .officialBrand),
                    Case(file: "fly-team", address: "team@news.fly.io", name: "Fly.io", expectedFraming: .brandCanvas, expectedSource: nil),
                    Case(file: "auckland", address: "studentinfo@auckland.ac.nz", name: "University of Auckland", expectedFraming: .brandSafe, expectedSource: nil),
                    Case(file: "ledger-care", address: "care@ledger.fr", name: "Ledger", expectedFraming: .brandSafe, expectedSource: nil),
                    Case(file: "tesla-privacy", address: "privacy@tesla.com", name: "Tesla", expectedFraming: .brandSafe, expectedSource: .officialBrand)
                ]
                for item in cases {
                    let email = EmailAddress(item.address)!
                    let result = try await resolver.resolve(email: email, displayName: item.name, gravatar: false, website: true)
                    let candidates = CandidateSelection.recommended(result.candidates)
                    guard candidates.allSatisfy({ !$0.lowResolution }), let image = candidates.first,
                          NSImage(data: image.png) != nil else {
                        throw PortraitError.message("no clear public brand artwork for \(item.address): \(result.notes.joined(separator: "; "))")
                    }
                    if let expected = item.expectedFraming, image.effectiveFraming != expected {
                        throw PortraitError.message("unexpected framing for \(item.address): \(image.effectiveFraming.rawValue)")
                    }
                    if let expected = item.expectedSource, image.source != expected {
                        throw PortraitError.message("unexpected source for \(item.address): \(image.source.rawValue)")
                    }
                    let path = output.appendingPathComponent(item.file + ".png")
                    try image.png.write(to: path, options: .atomic)
                    print("PASS address=\(item.address) source=\(image.source.rawValue) original=\(image.width)x\(image.height) subject=\(image.subjectWidth ?? image.width)x\(image.subjectHeight ?? image.height) framing=\(image.effectiveFraming.rawValue) output=\(path.path)")
                }

                let milkRun = try await resolver.resolve(email: EmailAddress("help@milkrun.com")!, displayName: "MILKRUN", gravatar: false, website: true)
                guard milkRun.candidates.allSatisfy({ !$0.lowResolution }), CandidateSelection.recommended(milkRun.candidates).allSatisfy({ min($0.width, $0.height) >= PortraitPolicy.minimumRasterDimension || $0.vector }) else {
                    throw PortraitError.message("MILKRUN retained a low-resolution candidate")
                }
                print("PASS address=help@milkrun.com low_resolution_candidates=0 usable_candidates=\(CandidateSelection.recommended(milkRun.candidates).count)")
                print("REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0 MAIL_MESSAGES_READ=0 FULL_EMAILS_SENT=0")
                exit(0)
            } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }
}

/// Live, public-web-only acceptance for v0.9.2. The addresses below are the
/// exact user-reported public institution/brand cases. Mail and Contacts are
/// not opened, and only rendered public images are written to the output folder.
@MainActor enum LiveV092Smoke {
    static func run(arguments: [String]) {
        Task {
            do {
                guard let index = arguments.firstIndex(of: "--output-dir"), index + 1 < arguments.count else {
                    throw PortraitError.message("--live-v092-smoke requires --output-dir PATH")
                }
                let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let resolver = AvatarResolver()
                let people = [
                    ("vuw-jens-dietrich", "jens.dietrich@vuw.ac.nz", "Jens Dietrich"),
                    ("vuw-stephen-macdonell", "stephen.macdonell@vuw.ac.nz", "Stephen MacDonell")
                ]
                for (file, address, name) in people {
                    let result = try await resolver.resolve(email: EmailAddress(address)!, displayName: name, gravatar: false, website: true)
                    guard let image = result.candidates.first(where: { $0.source == .institutionProfile }),
                          image.effectiveFraming == .personFill,
                          NSImage(data: image.png) != nil else {
                        throw PortraitError.message("missing exact institutional portrait: \(name)")
                    }
                    let path = output.appendingPathComponent(file + ".png")
                    try image.png.write(to: path, options: .atomic)
                    print("PASS person=\(name) source=\(image.source.rawValue) original=\(image.width)x\(image.height) profile=\(result.reports.first(where: { $0.source == .institutionProfile })?.target ?? "") output=\(path.path)")
                }

                let placeholder = try await resolver.resolve(email: EmailAddress("xiang.guo@vuw.ac.nz")!, displayName: "Shawn Guo", gravatar: false, website: true)
                guard !placeholder.candidates.contains(where: { $0.source == .institutionProfile }),
                      placeholder.reports.contains(where: { $0.source == .institutionProfile && $0.outcome == .unavailable && $0.detail.localizedCaseInsensitiveContains("placeholder") }),
                      let fallback = CandidateSelection.recommended(placeholder.candidates).first,
                      fallback.source.isBrand else {
                    throw PortraitError.message("flat VUW placeholder was accepted as a person portrait")
                }
                let fallbackPath = output.appendingPathComponent("vuw-shawn-guo-institution-fallback.png")
                try fallback.png.write(to: fallbackPath, options: .atomic)
                print("PASS person=Shawn Guo placeholder=rejected fallback=\(fallback.source.rawValue) output=\(fallbackPath.path)")

                for (file, address, name) in [
                    ("rewrite", "hello@rewrite.so", "rewrite.so"),
                    ("linkedin", "invitations@linkedin.com", "LinkedIn")
                ] {
                    let result = try await resolver.resolve(email: EmailAddress(address)!, displayName: name, gravatar: false, website: true)
                    guard let image = CandidateSelection.recommended(result.candidates).first,
                          image.effectiveFraming == .brandCanvas,
                          image.layoutRevision == ImagePipeline.currentLayoutRevision,
                          NSImage(data: image.png) != nil else {
                        throw PortraitError.message("unexpected composed-canvas result: \(address)")
                    }
                    let path = output.appendingPathComponent(file + ".png")
                    try image.png.write(to: path, options: .atomic)
                    print("PASS address=\(address) source=\(image.source.rawValue) framing=\(image.effectiveFraming.rawValue) layout=\(image.layoutRevision ?? -1) output=\(path.path)")
                }
                print("REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0 MAIL_MESSAGES_READ=0 FULL_EMAILS_SENT=0 DISPLAY_NAMES_SENT_TO_INSTITUTION=3 LEGACY_DIRECTORY_LOCAL_IDS_SENT_TO_SAME_INSTITUTION=1")
                exit(0)
            } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }
}

/// Live, public-network-only acceptance for v0.9.3 recovery sources. The test
/// uses role addresses only to select public sender domains; person sources are
/// disabled, Mail and Contacts are never opened, and assets go to output-dir.
@MainActor enum LiveV093Smoke {
    static func run(arguments: [String]) {
        Task {
            do {
                guard let index = arguments.firstIndex(of: "--output-dir"), index + 1 < arguments.count else {
                    throw PortraitError.message("--live-v093-smoke requires --output-dir PATH")
                }
                let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                // Start with several real no-record domains in parallel so a
                // cold negative lookup cannot occupy the queue and starve the
                // following real positive record.
                let bimi = PublicBIMI()
                let coldResults = try await withThrowingTaskGroup(of: (String, BIMILogo?).self) { group in
                    for domain in ["google.com", "gmail.com", "aucklanduni.ac.nz", "52pojie.net", "milkrun.com"] {
                        group.addTask {
                            do { return (domain, try await bimi.logo(for: domain)) }
                            catch { return (domain, nil) }
                        }
                    }
                    var values: [(String, BIMILogo?)] = []
                    for try await value in group { values.append(value) }
                    return values
                }
                guard coldResults.first(where: { $0.0 == "milkrun.com" })?.1?.recordDomain == "milkrun.com" else {
                    throw PortraitError.message("cold concurrent DNS queue starved a published BIMI record")
                }
                print("PASS bimi_cold_queue queries=5 positive_after_negatives=milkrun.com")
                let resolver = AvatarResolver()

                for (file, address, name) in [
                    ("bimi-milkrun", "help@milkrun.com", "MILKRUN"),
                    ("bimi-amazon-au", "prime@amazon.com.au", "Amazon"),
                    ("bimi-zoom", "no-reply@zoom.us", "Zoom")
                ] {
                    let result = try await resolver.resolve(email: EmailAddress(address)!, displayName: name, gravatar: false, website: true)
                    guard let image = result.candidates.first(where: { $0.source == .bimi }),
                          image.recommendedAutomatically,
                          NSImage(data: image.png) != nil else {
                        let report = result.reports.first(where: { $0.source == .bimi })?.detail ?? "no BIMI report"
                        throw PortraitError.message("missing clear BIMI logo for \(address): \(report); \(result.notes.joined(separator: "; "))")
                    }
                    let path = output.appendingPathComponent(file + ".png")
                    try image.png.write(to: path, options: .atomic)
                    let record = result.reports.first(where: { $0.source == .bimi })?.target ?? ""
                    print("PASS address=\(address) source=\(image.source.rawValue) record_domain=\(record) original=\(image.width)x\(image.height) framing=\(image.effectiveFraming.rawValue) output=\(path.path)")
                }

                let structured = try await resolver.resolveWebsite(at: URL(string: "https://oakywood.shop/")!)
                for candidate in structured.candidates {
                    print("TRACE website=oakywood.shop candidate=\(candidate.source.rawValue) original=\(candidate.width)x\(candidate.height) subject=\(candidate.subjectWidth ?? candidate.width)x\(candidate.subjectHeight ?? candidate.height) automatic=\(candidate.recommendedAutomatically) origin=\(candidate.origin)")
                }
                for report in structured.reports {
                    print("TRACE website=oakywood.shop report=\(report.source.rawValue) outcome=\(report.outcome.rawValue) count=\(report.count) detail=\(report.detail)")
                }
                guard let logo = structured.candidates.first(where: { $0.source == .siteLogo }),
                      logo.recommendedAutomatically,
                      NSImage(data: logo.png) != nil else {
                    throw PortraitError.message("oakywood.shop structured organization logo did not pass the quality gate")
                }
                let structuredPath = output.appendingPathComponent("structured-oakywood.png")
                try logo.png.write(to: structuredPath, options: .atomic)
                print("PASS website=oakywood.shop source=\(logo.source.rawValue) original=\(logo.width)x\(logo.height) framing=\(logo.effectiveFraming.rawValue) output=\(structuredPath.path)")

                let person = try await resolver.resolve(email: EmailAddress("zirun@aucklanduni.ac.nz")!, displayName: "Zirun Zhou", gravatar: false, website: true)
                guard let portrait = person.candidates.first(where: { $0.source == .institutionProfile }),
                      portrait.effectiveFraming == .personFill,
                      NSImage(data: portrait.png) != nil else {
                    throw PortraitError.message("aucklanduni.ac.nz alias did not return the unique exact institutional portrait")
                }
                let personPath = output.appendingPathComponent("aucklanduni-zirun-zhou.png")
                try portrait.png.write(to: personPath, options: .atomic)
                print("PASS person=Zirun_Zhou domain=aucklanduni.ac.nz source=\(portrait.source.rawValue) original=\(portrait.width)x\(portrait.height) output=\(personPath.path)")

                let brandStart = Date()
                let canonical = try await resolver.resolveWebsite(at: URL(string: "https://www.auckland.ac.nz/")!)
                print("TRACE website=auckland.ac.nz seconds=\(String(format: "%.3f", Date().timeIntervalSince(brandStart))) candidates=\(canonical.candidates.count)")
                for report in canonical.reports {
                    print("TRACE website=auckland.ac.nz report=\(report.source.rawValue) outcome=\(report.outcome.rawValue) detail=\(report.detail)")
                }
                let institution = try await resolver.resolve(email: EmailAddress("studentinfo@aucklanduni.ac.nz")!, displayName: "University of Auckland", gravatar: false, website: true)
                guard !institution.candidates.contains(where: { $0.source == .institutionProfile }),
                      let mark = CandidateSelection.recommended(institution.candidates).first,
                      mark.source.isBrand,
                      NSImage(data: mark.png) != nil else {
                    throw PortraitError.message("institution alias did not fall back to a clear canonical-site brand mark")
                }
                let institutionPath = output.appendingPathComponent("aucklanduni-brand-fallback.png")
                try mark.png.write(to: institutionPath, options: .atomic)
                print("PASS address=studentinfo@aucklanduni.ac.nz person_match=0 source=\(mark.source.rawValue) original=\(mark.width)x\(mark.height) output=\(institutionPath.path)")

                print("REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0 MAIL_MESSAGES_READ=0 EMAIL_HASHES_SENT=0 FULL_EMAILS_SENT=0 DISPLAY_NAMES_SENT_TO_INSTITUTION=1 DNS_QUERIES_CONTAIN_DOMAINS_ONLY=1")
                exit(0)
            } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }
}

/// Live, public-network-only acceptance for 0.9.4 source ordering. It sends
/// domains to their own websites/DNS and, only after those paths have no clear
/// image, the registrable domain to Google Site Icon. Mail and Contacts stay
/// untouched; rendered previews go only to output-dir.
@MainActor enum LiveV094Smoke {
    static func run(arguments: [String]) {
        Task {
            do {
                guard let index = arguments.firstIndex(of: "--output-dir"), index + 1 < arguments.count else {
                    throw PortraitError.message("--live-v094-smoke requires --output-dir PATH")
                }
                let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let resolver = AvatarResolver()
                for (file, address, name, source) in [
                    ("google-official-brand", "noreply-accounts@google.com", "Google", CandidateSource.officialBrand),
                    ("bellroy-touch", "support@bellroy.com", "Bellroy", .touchIcon),
                    ("vercel-touch", "notifications@vercel.com", "Vercel", .touchIcon)
                ] {
                    let result = try await resolver.resolve(email: EmailAddress(address)!, displayName: name, gravatar: false, website: true)
                    guard let image = result.candidates.first(where: \.recommendedAutomatically), image.source == source,
                          image.recommendedAutomatically, NSImage(data: image.png) != nil else {
                        throw PortraitError.message("unexpected preferred source for \(address): \(result.candidates.first(where: \.recommendedAutomatically)?.source.rawValue ?? "none")")
                    }
                    if address == "notifications@vercel.com" {
                        guard let published = result.candidates.first(where: { $0.source == .bimi }), !published.circularSuitable, published.score < image.score else {
                            throw PortraitError.message("Vercel wide BIMI wordmark should remain traceable without replacing the circle-suitable icon")
                        }
                        print("PASS address=\(address) published_bimi=retained avatar_suitable=false")
                    }
                    let path = output.appendingPathComponent(file + ".png")
                    try image.png.write(to: path, options: .atomic)
                    print("PASS address=\(address) preferred=\(image.source.rawValue) original=\(image.width)x\(image.height) framing=\(image.effectiveFraming.rawValue) output=\(path.path)")
                }
                print("SOURCE_ORDER=person>circle-suitable-BIMI>official>touchIcon>manifest>siteLogo>favicon>domainIcon")
                print("REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0 MAIL_MESSAGES_READ=0 EMAIL_LOCAL_PARTS_SENT_TO_DOMAIN_ICON=0 DISPLAY_NAMES_SENT_TO_DOMAIN_ICON=0")
                exit(0)
            } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }
}

/// Opens a copied real-library state without starting SwiftUI tasks, Mail, or
/// Contacts. This verifies the on-open v0.9.4 migration and display grouping
/// against the same sender corpus that the installed app will read.
@MainActor enum V094StateSmoke {
    static func run(arguments: [String]) -> Int32 {
        do {
            guard let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count else {
                throw PortraitError.message("--v094-state-smoke requires --data-dir PATH")
            }
            let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            let changes = root.appendingPathComponent("changes.json")
            let automation = root.appendingPathComponent("automation.json")
            let changesBefore = digest(try Data(contentsOf: changes))
            let automationBefore = digest(try Data(contentsOf: automation))
            let started = Date()
            let model = AppModel(demo: false, rootOverride: root)
            let loadSeconds = Date().timeIntervalSince(started)
            guard model.launchError == nil else { throw PortraitError.message(model.launchError!) }
            guard loadSeconds < 3 else { throw PortraitError.message("copied sender library migration exceeded the interactive launch budget") }
            guard model.rows.count == 903, Set(model.rows.map(\.id)).count == model.rows.count else {
                throw PortraitError.message("sender corpus count or identity changed")
            }
            func row(_ address: String) throws -> SenderRow {
                guard let value = model.rows.first(where: { $0.id == address }) else {
                    throw PortraitError.message("missing expected sender")
                }
                return value
            }
            guard try row("support@bellroy.com").chosen?.source == .touchIcon else {
                throw PortraitError.message("Bellroy did not migrate to Touch Icon")
            }
            guard try row("notifications@vercel.com").chosen?.source == .touchIcon else {
                throw PortraitError.message("Vercel did not migrate to Touch Icon")
            }
            guard AutomaticLookupPolicy.due(try row("support@bellroy.com"), website: true, gravatar: false, now: Date()),
                  AutomaticLookupPolicy.due(try row("notifications@vercel.com"), website: true, gravatar: false, now: Date()) else {
                throw PortraitError.message("changed automatic brand choices were not queued for BIMI verification")
            }
            let mia = try row("mia.chillgood@personal.test")
            model.section = "existing"
            guard mia.current?.image != nil, model.sectionRows.contains(where: { $0.id == mia.id }),
                  !model.rows.filter({ !$0.completed && $0.current?.image == nil }).contains(where: { $0.id == mia.id }) else {
                throw PortraitError.message("existing Contacts photo classification is wrong")
            }
            let elliottRows = model.rows.filter { $0.name.localizedCaseInsensitiveContains("Elliott Wen") }
            let elliottGroups = SenderGrouping.groups(elliottRows)
            guard elliottRows.count == 3, elliottGroups.count == 2,
                  elliottGroups.contains(where: { Set($0.members.map(\.id)) == Set(["elliott.wen@auckland.ac.nz", "elliott.wen@personal.test"]) }) else {
                throw PortraitError.message("Elliott identity grouping is wrong")
            }
            guard AutomaticLookupPolicy.due(try row("noreply-accounts@google.com"), website: true, gravatar: false, now: Date()) else {
                throw PortraitError.message("Google missing-source recovery is not scheduled")
            }
            guard digest(try Data(contentsOf: changes)) == changesBefore,
                  digest(try Data(contentsOf: automation)) == automationBefore else {
                throw PortraitError.message("state migration touched Contacts journal or automation preferences")
            }
            print(String(format: "PASS senders=903 unique=903 load_seconds=%.3f bellroy=touchIcon+refresh-due vercel=touchIcon+refresh-due", loadSeconds))
            print("PASS existing_contact_photo=classified elliott_groups=2 elliott_emails=3 google_recovery=due")
            print("REAL_CONTACTS_READ=0 REAL_CONTACTS_WRITTEN=0 MAIL_MESSAGES_READ=0 CHANGE_JOURNAL_UNCHANGED=1 AUTOMATION_UNCHANGED=1")
            return 0
        } catch {
            print("FAIL \(error.localizedDescription)")
            return 1
        }
    }
}
