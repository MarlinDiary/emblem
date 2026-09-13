import Foundation
public enum PortraitPolicy {
    public static let minimumRasterDimension = 128
    public static func qualityScore(width: Int, height: Int, vector: Bool) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let short = min(width, height), long = max(width, height)
        let aspectPenalty = Int((1 - Double(short) / Double(long)) * 400)
        return (vector ? 600 : min(short, 512)) - aspectPenalty
    }
    public static func mayDelete(createdByApp: Bool, imageMatches: Bool, historyUnchanged: Bool) -> Bool {
        createdByApp && imageMatches && historyUnchanged
    }
}
