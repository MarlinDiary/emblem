import XCTest
import AppKit
import PortraitCore
@testable import Emblem

private func v094PNG(_ size: Int) -> Data {
    let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    return image.representation(using:.png,properties:[:])!
}

final class V094AppIdentityTests: XCTestCase {
    private func row(_ email: String, _ name: String) -> SenderRow {
        .init(email: EmailAddress(email)!, name: name)
    }

    func testExactPersonNameCanDisplayGroupAcrossDomainsWhenOneRowHasPersonEvidence() {
        var university = row("elliott.wen@auckland.ac.nz", "Elliott Wen")
        university.candidates = [AvatarCandidate(source: .institutionProfile, origin: "fixture", width: 180, height: 180, png: Data([1]))]
        university.current = ContactSnapshot(id: "university-card", name: "Elliott Wen", emails: [university.id], image: nil)
        let personal = row("elliott.wen@personal.test", "Elliott Wen")
        XCTAssertEqual(SenderGrouping.groups([university, personal]).count, 1)
        XCTAssertEqual(Set(SenderGrouping.groups([university, personal])[0].members.map(\.id)), Set([university.id, personal.id]))
    }

    func testBrandNotificationWithViaSuffixDoesNotJoinPersonIdentity() {
        var university = row("elliott.wen@auckland.ac.nz", "Elliott Wen")
        university.candidates = [AvatarCandidate(source: .institutionProfile, origin: "fixture", width: 180, height: 180, png: Data([1]))]
        let personal = row("elliott.wen@personal.test", "Elliott Wen")
        let invitation = row("invitations@linkedin.com", "Elliott Wen via LinkedIn")
        XCTAssertEqual(SenderGrouping.groups([university, personal, invitation]).count, 2)
    }

    func testSameNameAcrossSharedProvidersWithoutPersonEvidenceStaysSeparate() {
        XCTAssertEqual(SenderGrouping.groups([
            row("one@gmail.com", "Alex Chen"), row("two@outlook.com", "Alex Chen")
        ]).count, 2)
    }

    @MainActor
    func testExistingContactPhotoHasItsOwnSectionInsteadOfPendingOrApplied() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(demo: true, rootOverride: root)
        var existing = row("fixture-person-contacts@personal.test", "Mia Miu")
        existing.current = .init(id: "mia", name: "Mia Miu", emails: [existing.id], image: Data([1]))
        model.rows = [existing]
        XCTAssertEqual(model.existingPhotoCount, 1)
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.appliedCount, 0)
        model.section = "existing"
        XCTAssertEqual(model.sectionRows.map(\.id), [existing.id])
    }

    @MainActor
    func testMigrationReselectsSharperManifestButPreservesManualChoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = AvatarCandidate(source: .manifest, origin: "manifest", width: 512, height: 512, png: v094PNG(512), layoutRevision: 3)
        let touch = AvatarCandidate(source: .touchIcon, origin: "touch", width: 256, height: 256, png: v094PNG(256), layoutRevision: 3)
        var automatic = row("auto@company.org", "Company")
        automatic.candidates = [manifest, touch]; automatic.selectedCandidate = touch.id; automatic.selectionIsManual = false; automatic.lookupPolicy = "v092|true|false|company.org"
        var manual = row("manual@company.org", "Company")
        manual.candidates = [manifest, touch]; manual.selectedCandidate = touch.id; manual.selectionIsManual = true
        try JSONEncoder().encode([automatic, manual]).write(to: root.appendingPathComponent("senders.json"))
        let model = AppModel(demo: false, rootOverride: root)
        XCTAssertEqual(model.rows.first{$0.id==automatic.id}?.chosen?.source, .manifest)
        XCTAssertEqual(model.rows.first{$0.id==automatic.id}?.chosen?.layoutRevision, 3, "Source re-ranking must not synchronously re-render an already safe cached image")
        XCTAssertNil(model.rows.first{$0.id==automatic.id}?.lookupPolicy)
        XCTAssertEqual(model.rows.first{$0.id==manual.id}?.selectedCandidate, touch.id)
    }
}
