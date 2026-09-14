import XCTest
@testable import PortraitCore
final class StandardPersonMarkupTests:XCTestCase {
 let email=EmailAddress("alex@research.stanford.edu")!,page=URL(string:"https://www.stanford.edu/people/alex-researcher")!
 func card(_ name:String="Alex Researcher",email:String="alex@research.stanford.edu",photo:String="/alex.jpg")->String {
  "<article itemscope itemtype='https://schema.org/Person'><h2 itemprop='name'>\(name)</h2><a itemprop='email' href='mailto:\(email)'>Email</a><img itemprop='image' src='\(photo)'></article>"
 }
 func testMicrodataOutsideSpecialInstitutionRegistry() {XCTAssertEqual(OrganizationProfilePage.image(html:card(),page:page,email:email,name:"Alex Researcher")?.path,"/alex.jpg")}
 func testHCardExactIdentity() {
  let html="<div class='h-card'><span class='p-name'>Alex Researcher</span><a class='u-email' href='mailto:alex@research.stanford.edu?subject=Hello'>Email</a><img class='u-photo' src='/alex.jpg'></div>"
  XCTAssertEqual(OrganizationProfilePage.image(html:html,page:page,email:email,name:"Alex Researcher")?.path,"/alex.jpg")
 }
 func testNeighbourOrNestedPersonCannotCompleteIdentity() {
  let html="<div itemscope itemtype='https://schema.org/Person'><h2 itemprop='name'>Alex Researcher</h2>"+card("Other Person")+"</div>"
  XCTAssertNil(OrganizationProfilePage.image(html:html,page:page,email:email,name:"Alex Researcher"))
  XCTAssertNil(OrganizationProfilePage.image(html:card(email:"different@stanford.edu")+card("Other Person"),page:page,email:email,name:"Alex Researcher"))
 }
 func testConflictingPhotosAndHostImpersonationRejected() {
  XCTAssertNil(OrganizationProfilePage.image(html:card()+card(photo:"/other.jpg"),page:page,email:email,name:"Alex Researcher"))
  XCTAssertNil(OrganizationProfilePage.image(html:card(),page:URL(string:"https://stanford.edu.other.test/")!,email:email,name:"Alex Researcher"))
  XCTAssertNil(OrganizationProfilePage.image(html:card(photo:"http://127.0.0.1/p.jpg"),page:page,email:email,name:"Alex Researcher"))
 }
 func testAdditionalStandardDirectoryPathAndBound() {
  let html="<a href='/faculty'>Faculty</a><a href='/our-team'>Team</a><a href='https://other.test/team'>Other</a>"
  XCTAssertEqual(OrganizationProfilePage.links(html:html,page:page,email:email,name:"Alex Researcher").map(\.path),["/faculty","/our-team"])
 }
}
