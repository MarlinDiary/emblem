import XCTest
@testable import PortraitCore
final class V016OrganizationProfilesTests:XCTestCase {
    private let email=EmailAddress("v.terragni@auckland.ac.nz")!
    private let page=URL(string:"https://www.auckland.ac.nz/people/valerio-terragni")!
    private func html(email:String="v.terragni@auckland.ac.nz",name:String="Valerio Terragni",image:String="/portrait.jpg")->String {"<script type=\"application/ld+json\">{\"@graph\":[{\"@type\":\"Person\",\"name\":\"\(name)\",\"email\":\"\(email)\",\"image\":\"\(image)\"}]}</script>"}
    func testExactPublicEmailAndNameMatch() {
        XCTAssertEqual(OrganizationProfilePage.image(html:html(),page:page,email:email,name:"Valerio Terragni")?.absoluteString,"https://www.auckland.ac.nz/portrait.jpg")
    }
    func testSameNameDifferentEmailIsRejected() {
        XCTAssertNil(OrganizationProfilePage.image(html:html(email:"different@auckland.ac.nz"),page:page,email:email,name:"Valerio Terragni"))
    }
    func testDifferentNameOrUnrelatedWebsiteIsRejected() {
        XCTAssertNil(OrganizationProfilePage.image(html:html(name:"Another Person"),page:page,email:email,name:"Valerio Terragni"))
        XCTAssertNil(OrganizationProfilePage.image(html:html(),page:URL(string:"https://linkedin.com/")!,email:email,name:"Valerio Terragni"))
    }
    func testMultipleDifferentPhotosAreNotGuessed() {
        XCTAssertNil(OrganizationProfilePage.image(html:html()+html(image:"/other.jpg"),page:page,email:email,name:"Valerio Terragni"))
    }
    func testUnregisteredAcademicInstitutionKeepsMailboxesIndependent() {
        XCTAssertTrue(InstitutionalProfilePolicy.keepsMailboxIndependent(EmailAddress("staff@stanford.edu")!))
        XCTAssertTrue(InstitutionalProfilePolicy.isEligible(email:EmailAddress("valerio@staff.university.ac.nz")!,displayName:"Valerio Terragni"))
        XCTAssertFalse(InstitutionalProfilePolicy.isEligible(email:EmailAddress("person@outlook.com")!,displayName:"Valerio Terragni"))
    }
}
