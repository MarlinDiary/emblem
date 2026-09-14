import Foundation
import SwiftSoup

/// Organization-independent Schema.org Person support. A name alone is never
/// enough: public email + full name must both match, on the sender's own domain.
public enum OrganizationProfilePage {
    public static func image(html:String,page:URL,email:EmailAddress,name:String)->URL? {
        guard html.utf8.count <= 1_000_000, owns(page,email:email) else{return nil}
        var matches:[URL]=[]
        for script in IconDiscovery.matches(#"<script\b[^>]*type\s*=\s*[\"']application/ld\+json[\"'][^>]*>([\s\S]*?)</script\s*>"#,html) {
            guard let body=IconDiscovery.value(script,group:1,in:html),let data=body.data(using:.utf8),let json=try? JSONSerialization.jsonObject(with:data) else{continue}
            func visit(_ value:Any) {
                if let list=value as? [Any] {for item in list {visit(item)};return}
                guard let node=value as? [String:Any] else{return}
                let types=(node["@type"] as? [String]) ?? (node["@type"] as? String).map{[$0]} ?? []
                let names=(node["name"] as? String).map{InstitutionalProfilePolicy.folded($0)}
                let emails=(node["email"] as? [String]) ?? (node["email"] as? String).map{[$0]} ?? []
                if types.contains(where:{$0=="Person" || $0=="https://schema.org/Person"}),names==InstitutionalProfilePolicy.folded(name),
                   emails.contains(where:{$0.replacingOccurrences(of:"mailto:",with:"").trimmingCharacters(in:.whitespacesAndNewlines).caseInsensitiveCompare(email.value) == .orderedSame}) {
                    let source=(node["image"] as? String) ?? (node["image"] as? [String:Any])?["url"] as? String ?? (node["image"] as? [String:Any])?["contentUrl"] as? String
                    if let source,let url=URL(string:source,relativeTo:page)?.absoluteURL,NetworkPolicy.isAllowedURL(url) {matches.append(url)}
                }
                for (key,value) in node where key != "image" {if value is [String:Any] || value is [Any] {visit(value)}}
            }
            visit(json)
        }
        matches += markupImages(html:html,page:page,email:email,name:name)
        let unique=Set(matches)
        return unique.count==1 ? unique.first:nil
    }
    /// Read actual DOM scopes: a neighbouring employee's email/image never
    /// completes another person's identity. Supports standard microdata/h-card.
    private static func markupImages(html:String,page:URL,email:EmailAddress,name:String)->[URL] {
        guard let doc=try? SwiftSoup.parse(html,page.absoluteString) else{return []}
        func personScope(_ e:Element)->Bool {
            let type=(try? e.attr("itemtype")) ?? ""
            return type.split(whereSeparator: \.isWhitespace).contains { $0 == "https://schema.org/Person" || $0 == "http://schema.org/Person" }
        }
        func belongs(_ element:Element,to root:Element)->Bool {
            var parent=element.parent()
            while let e=parent {
                if e === root {return true}
                if personScope(e) || e.hasClass("h-card") || e.hasClass("vcard") {return false}
                parent=e.parent()
            }
            return element === root
        }
        func values(_ root:Element,_ selector:String,_ attrs:[String])->[String] {
            guard let nodes=try? root.select(selector).array() else{return []}
            return nodes.filter{belongs($0,to:root)}.compactMap { node in
                for attr in attrs {if let value=try? node.attr(attr),!value.isEmpty {return value}}
                return try? node.text()
            }
        }
        let roots=(try? doc.select("[itemscope][itemtype], .h-card, .vcard").array()) ?? []
        var result:[URL]=[]
        for root in roots.prefix(200) {
            let micro=personScope(root)
            guard micro || root.hasClass("h-card") || root.hasClass("vcard") else{continue}
            let names=values(root,micro ? "[itemprop~=name]":".p-name, .fn",["content"])
            let emails=values(root,micro ? "[itemprop~=email]":".u-email, .email",["content","href"])
            let matchingNames=Set(names.map(InstitutionalProfilePolicy.folded))
            guard matchingNames == [InstitutionalProfilePolicy.folded(name)],emails.contains(where:{
                let value=$0.replacingOccurrences(of:"mailto:",with:"").split(separator:"?").first.map(String.init) ?? ""
                return (value.removingPercentEncoding ?? value).trimmingCharacters(in:.whitespacesAndNewlines).caseInsensitiveCompare(email.value) == .orderedSame
            }) else{continue}
            for source in values(root,micro ? "[itemprop~=image]":".u-photo, .photo",["content","src","href"]) {
                if let url=URL(string:source,relativeTo:page)?.absoluteURL,NetworkPolicy.isAllowedURL(url) {result.append(url)}
            }
        }
        return result
    }
    public static func owns(_ url:URL,email:EmailAddress)->Bool {
        guard NetworkPolicy.isAllowedURL(url),let host=url.host else{return false}
        return DomainRouting.primaryHost(for:host)==DomainRouting.primaryHost(for:email.domain)
    }
    static func links(html:String,page:URL,email:EmailAddress,name:String)->[URL] {
        let tokens=InstitutionalProfilePolicy.folded(name).split(separator:" ").map(String.init)
        var profiles:[URL]=[],directories:[URL]=[]
        for anchor in IconDiscovery.matches(#"<a\b[^>]*>"#,html) {
            guard let tag=IconDiscovery.value(anchor,group:0,in:html),let href=IconDiscovery.attributes(tag)["href"],
                  let url=URL(string:href,relativeTo:page)?.absoluteURL,owns(url,email:email),url.query==nil,url.fragment==nil else{continue}
            let path=url.path.lowercased()
            if tokens.count>=2,tokens.allSatisfy({path.contains($0)}),path != page.path {profiles.append(url)}
            else if ["/people","/staff","/team","/directory","/about/team","/about/people","/faculty","/research/people","/about/staff","/our-people","/our-team","/people/faculty","/staff-directory"].contains(path.trimmingCharacters(in:CharacterSet(charactersIn:"/" )).isEmpty ? "/" : "/"+path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))) {directories.append(url)}
        }
        var seen=Set<URL>()
        return (Array(profiles.prefix(2))+Array(directories.prefix(2))).filter{seen.insert($0).inserted}
    }
}

extension PublicInstitutionalProfiles {
    func organizationPortrait(email:EmailAddress,name:String)async throws->InstitutionalPortrait? {
        guard !email.isSharedProvider,let root=URL(string:"https://"+DomainRouting.primaryHost(for:email.domain)+"/") else{return nil}
        var pending=[root],visited=Set<URL>()
        // Small bounded discovery, not a web crawler or a same-name search.
        while let url=pending.first,visited.count<5 {
            pending.removeFirst();guard visited.insert(url).inserted else{continue}
            let page:WebResource
            do {page=try await client.fetch(url,limit:1_000_000)}
            catch let e as HTTPResourceError where [403,404].contains(e.status) {continue}
            try Task.checkCancellation()
            guard OrganizationProfilePage.owns(page.url,email:email),let html=String(data:page.data,encoding:.utf8) else{continue}
            if let image=OrganizationProfilePage.image(html:html,page:page.url,email:email,name:name) {
                let resource=try await client.fetch(image,limit:4_000_000)
                return InstitutionalPortrait(matchedName:name,profileURL:page.url,image:resource)
            }
            pending.append(contentsOf:OrganizationProfilePage.links(html:html,page:page.url,email:email,name:name).filter{!visited.contains($0)})
        }
        return nil
    }
}
