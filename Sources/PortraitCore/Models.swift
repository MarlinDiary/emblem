import Foundation
import CryptoKit

public enum PortraitError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public func digest(_ data: Data?) -> String {
    guard let data else { return "none" }
    let hex=Array("0123456789abcdef".utf8)
    return String(decoding:SHA256.hash(data:data).flatMap{[hex[Int($0 >> 4)],hex[Int($0 & 15)]]},as:UTF8.self)
}

public struct EmailAddress: Hashable, Codable, Sendable {
    public let value: String
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 254, trimmed.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}$"#, options: .regularExpression) != nil else { return nil }
        let parts = trimmed.split(separator: "@")
        guard parts.count == 2, parts[0].count <= 64, !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !trimmed.contains(".."), parts[1].split(separator: ".").allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        // Preserve local-part case for address identity. Gravatar has its own normalization.
        value = String(parts[0]) + "@" + parts[1].lowercased()
    }
    public var domain: String { String(value.split(separator: "@")[1]) }
    public func suggestedDisplayName(in input: String) -> String {
        for line in input.components(separatedBy: .newlines) {
            guard let range = line.range(of: "<" + value + ">", options: .caseInsensitive) else { continue }
            let prefix = line[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if !prefix.isEmpty, !prefix.contains("@"), !prefix.contains("<"), prefix.count <= 120 { return prefix }
        }
        return String(value.split(separator: "@")[0])
    }
    public var gravatarURL: URL { URL(string: "https://www.gravatar.com/avatar/\(digest(Data(value.lowercased().utf8)))?s=512&d=404&r=g")! }
    public var libravatarURL: URL { URL(string: "https://seccdn.libravatar.org/avatar/\(digest(Data(value.lowercased().utf8)))?s=512&d=404")! }
    public var isSharedProvider: Bool {
        ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "yahoo.co.uk", "aol.com", "qq.com", "163.com", "126.com", "proton.me", "protonmail.com", "pm.me", "fastmail.com", "hey.com", "gmx.com", "mail.com"].contains(DomainRouting.primaryHost(for:domain))
    }
    public static func parseList(_ text: String) -> [EmailAddress] {
        let regex = try! NSRegularExpression(pattern: #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}"#)
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text), let email = EmailAddress(String(text[range])), seen.insert(email.value).inserted else { return nil }
            return email
        }
    }
}

public enum CandidateSource: String, Codable, Sendable {
    case gravatar, libravatar, profile, institutionProfile, officialBrand, bimi, siteLogo, touchIcon, manifest, favicon, domainIcon, manual, monogram
    public var label: String {
        switch self {
        case .gravatar: return "Gravatar · Email-linked portrait"
        case .libravatar: return "Libravatar · Email-linked portrait"
        case .profile: return "Public Profile · Person photo"
        case .institutionProfile: return "Organization Directory · Person photo"
        case .officialBrand: return "Official Media · Brand artwork"
        case .bimi: return "BIMI DNS · Domain-published brand artwork"
        case .siteLogo: return "Website Data · Organization logo"
        case .touchIcon: return "Apple Touch Icon · Website icon"
        case .manifest: return "Web App Icon · Website icon"
        case .favicon: return "Website Icon · Not identity verification"
        case .domainIcon: return "Google Site Icon · Domain icon service"
        case .manual: return "Chosen manually"
        case .monogram: return "Monogram · Generated on this Mac"
        }
    }
    public var isBrand: Bool {
        switch self { case .gravatar, .libravatar, .profile, .institutionProfile, .manual, .monogram: return false; default: return true }
    }
}

public enum BrandArtwork: String, Codable, Sendable { case logo, appIcon }

public enum AvatarFraming: String, Codable, Sendable {
    case personFill, brandSafe, brandCanvas, brandMaskable
}

public struct AvatarCandidate: Identifiable, Codable, Sendable {
    public let id: UUID
    public let source: CandidateSource
    public let origin: String
    public let width: Int
    public let height: Int
    public let vector: Bool
    public var png: Data
    public var maskable: Bool?
    public var framing: AvatarFraming?
    public var subjectWidth: Int?
    public var subjectHeight: Int?
    public var layoutRevision: Int?
    public var artwork: BrandArtwork?
    /// Was this asset explicitly declared by the current homepage/manifest,
    /// rather than found at a conventional but potentially obsolete path?
    public var declared: Bool?
    public var visualQuality: AvatarVisualQuality?
    public init(source: CandidateSource, origin: String, width: Int, height: Int, vector: Bool = false, png: Data, maskable: Bool = false, framing: AvatarFraming? = nil, subjectWidth: Int? = nil, subjectHeight: Int? = nil, layoutRevision: Int? = ImagePipeline.currentLayoutRevision, artwork: BrandArtwork? = nil, id: UUID = UUID()) {
        self.id = id; self.source = source; self.origin = origin; self.width = width; self.height = height; self.vector = vector; self.png = png; self.maskable = maskable; self.framing = framing; self.subjectWidth = subjectWidth; self.subjectHeight = subjectHeight; self.layoutRevision = layoutRevision; self.artwork = artwork
    }
    public var effectiveFraming: AvatarFraming { framing ?? (source.isBrand ? (maskable == true ? .brandMaskable : .brandSafe) : .personFill) }
    public var circularSuitable: Bool {
        let w = subjectWidth ?? width, h = subjectHeight ?? height
        // BIMI is the strongest domain-published brand evidence, but the SVG can
        // still contain a very wide wordmark. Prefer it only when both its canvas
        // and visible mark remain legible inside Mail's circular presentation.
        if source == .bimi {
            return Double(min(width,height)) / Double(max(1,max(width,height))) >= 0.9
                && Double(min(w,h)) / Double(max(1,max(w,h))) >= 0.48
        }
        let minimum = source == .siteLogo ? 0.58 : source.isBrand ? 0.62 : 0.9
        return Double(min(w,h)) / Double(max(1,max(w,h))) >= minimum
    }
    public var visuallyUsable: Bool {
        !lowResolution && visualQuality?.isBlank != true && !(source.isBrand && !vector && visualQuality?.isSoft == true)
    }
    public var recommendedAutomatically: Bool {
        return visuallyUsable && (circularSuitable || readableBrandFallback)
    }
    private var readableBrandFallback: Bool {
        // Horizontal does not mean illegible: a smile, arrow or short wordmark
        // can be excellent brand evidence. Require measured delivered pixels and
        // safe framing, not just a prestigious source or a square SVG canvas.
        guard source.isBrand, source != .domainIcon, let quality=visualQuality,
              !quality.isBlank, !quality.isSoft, effectiveFraming != .personFill else { return false }
        let w=subjectWidth ?? width, h=subjectHeight ?? height
        let aspect=Double(h)/Double(max(1,w))
        guard aspect >= 0.15, aspect < 1 else { return false }
        let squareCanvas=Double(min(width,height))/Double(max(1,max(width,height))) >= 0.9
        if squareCanvas { return true }
        // Rectangular organization assets must be an identified logo or a
        // readable wordmark; a landscape/social-preview card is not an avatar.
        return (source == .siteLogo || source == .officialBrand) && (artwork == .logo || aspect <= 0.35)
    }
    public var score: Int {
        let sourcePriority: Int = switch source {
        case .monogram: -10_000
        case .manual: 70_000
        case .gravatar, .libravatar, .profile, .institutionProfile: 60_000
        case .bimi: 50_000
        case .officialBrand: 30_400
        case .touchIcon: 30_000
        case .manifest: 30_000
        case .siteLogo: 30_400
        case .favicon: 30_000
        case .domainIcon: 10_000
        }
        let value = PortraitPolicy.qualityScore(width:width,height:height,vector:vector) * 3
            + sourcePriority
            + (declared == true ? 1_200 : 0)
            + (effectiveFraming == .brandMaskable && recommendedAutomatically ? 150 : 0)
            - (Int((visualQuality?.frameFraction ?? 0) * 8_000))
            + (circularSuitable && !lowResolution ? 500 : 0)
            // Keep diagnostic low-resolution candidates visible without ever
            // letting source prestige outrank a usable first-party asset.
            - (!visuallyUsable ? 100_000 : 0)
        // A readable wide brand mark beats generated initials, but never a
        // usable compact brand mark. Keep source/quality ordering within this
        // fallback tier (including BIMI), without source prestige crossing tiers.
        return source.isBrand && !circularSuitable ? min(9_000, value / 10) : value
    }
    public var lowResolution: Bool { !vector && min(width, height) < PortraitPolicy.minimumRasterDimension }
}

public struct ContactSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var emails: [String]
    public var image: Data?
    public init(id: String, name: String, emails: [String], image: Data?) { self.id = id; self.name = name; self.emails = emails; self.image = image }
}

public enum ChangeState: String, Codable { case prepared, applied, undone, failed }
public struct ChangeRecord: Codable, Identifiable {
    public let id: UUID
    public let date: Date
    public let email: String
    public let source: String
    public let created: Bool
    public var contactID: String?
    public let beforeImage: Data?
    public var beforeName: String?
    public var afterName: String?
    public var beforeEmails: [String]?
    public var afterEmailsHash: String?
    public var managedKey: String?
    public var batchID: UUID?
    public var affectedEmails: [String]?
    public var afterPixelHash: String?
    public var afterHash: String
    public let historyToken: Data?
    public var state: ChangeState
    public var detail: String
    public init(email: String, source: String, created: Bool, contactID: String?, beforeImage: Data?, afterHash: String, historyToken: Data?) {
        id = UUID(); date = Date(); self.email = email; self.source = source; self.created = created; self.contactID = contactID; self.beforeImage = beforeImage; self.afterHash = afterHash; self.historyToken = historyToken; beforeEmails=nil; afterEmailsHash=nil; managedKey=nil; state = .prepared; detail = "Backed up; waiting for write verification"
    }
}

public func digestEmails(_ emails:[String]) -> String {
    digest(Data(emails.map { $0.lowercased() }.sorted().joined(separator:"\n").utf8))
}

/// Contacts matches case-insensitively. Keep original spelling and sender identity,
/// but never add a second native field for a case-only alias.
public func contactDistinctEmails(_ emails:[String])->[String] {
    var seen=Set<String>()
    return emails.filter{seen.insert($0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()).inserted}
}
