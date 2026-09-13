import Foundation

/// A deliberately small, reviewable catalogue of high-resolution assets linked
/// from first-party press/media pages. It is data rather than guessing: every
/// entry carries the first-party page that declares the asset, so additions can
/// be audited in a normal open-source review.
public struct OfficialBrandAsset: Sendable, Equatable {
    public let domains: Set<String>
    public let assetURL: URL
    public let evidenceURL: URL
    public let description: String
    public let artwork: BrandArtwork
    public let bundledResource:String?

    public init(domains: Set<String>, assetURL: URL, evidenceURL: URL, description: String, artwork: BrandArtwork = .logo, bundledResource:String? = nil) {
        self.domains = domains
        self.assetURL = assetURL
        self.evidenceURL = evidenceURL
        self.description = description; self.artwork = artwork;self.bundledResource=bundledResource
    }
}

public enum OfficialBrandAssets {
    public static let all: [OfficialBrandAsset] = [
        .init(domains:["claude.com","claude.ai"],
            assetURL:URL(string:"https://www-cdn.anthropic.com/ae59ca4ca194dac9c9dc3bc78c5829468cb0e8af.zip#Claude%20Spark%20-%20Clay.svg")!,
            evidenceURL:URL(string:"https://www.anthropic.com/press-kit")!,
            description:"Claude Spark mark from the official Anthropic media kit",artwork:.logo,bundledResource:"claude-icon"),
        .init(
            domains: ["google.com"],
            assetURL: URL(string: "https://storage.googleapis.com/gweb-uniblog-publish-prod/images/GoogleG_Social.max-1440x810.png")!,
            evidenceURL: URL(string: "https://blog.google/company-news/inside-google/company-announcements/gradient-g-logo-design/")!,
            description: "High-resolution gradient G from Google’s official brand announcement"
        ),
        .init(
            domains: ["raycast.com"],
            assetURL: URL(string: "https://fz1sd71lwhbqy6sh.public.blob.vercel-storage.com/press/images/logo/raycast-appicon.png?download=1")!,
            evidenceURL: URL(string: "https://www.raycast.com/press")!,
            description: "Official App Icon from the Raycast press kit", artwork: .appIcon
        ),
        .init(
            domains: ["adidas.com", "adidas.co.nz", "adidas.co.uk", "adidas.com.au", "adidas.de"],
            assetURL: URL(string: "https://res.cloudinary.com/confirmed-web/image/upload/v1713789247/adidas-group/media/pictures-videos/3-Bar_Logo_hggwec.jpg")!,
            evidenceURL: URL(string: "https://www.adidas-group.com/en/media/pictures-and-videos")!,
            description: "3-Bar Logo from the official adidas media centre"
        ),
        .init(
            domains: ["linkedin.com"],
            assetURL: URL(string: "https://delivery-p143253-e1476319.adobeaemcloud.com/adobe/assets/urn:aaid:aem:b29b53eb-bcf8-45c5-8df0-edd9f139d53c/original/as/brand-inlogo-download-fg-dsk-v01-2x.png")!,
            evidenceURL: URL(string: "https://brand.linkedin.com/in-logo")!,
            description: "[in] Logo from the official LinkedIn brand guidelines"
        ),
        .init(
            domains: ["tesla.com", "tesla.cn"],
            assetURL: URL(string: "https://digitalassets.tesla.com/tesla-contents/image/upload/f_auto,q_auto/tesla-logo-thumbnail.jpg")!,
            evidenceURL: URL(string: "https://www.tesla.com/support/troubleshoot-account")!,
            description: "High-resolution Tesla Logo from the official Tesla support site"
        )
    ]

    public static func bundledURL(for asset:OfficialBrandAsset)->URL? {
        guard let name=asset.bundledResource else{return nil}
        return Bundle.main.url(forResource:name,withExtension:"svg") ?? Bundle.module.url(forResource:name,withExtension:"svg")
    }
    public static func asset(for website: URL) -> OfficialBrandAsset? {
        guard let host = website.host else { return nil }
        let primary = DomainRouting.primaryHost(for: host)
        return all.first { $0.domains.contains(primary) }
    }
}
