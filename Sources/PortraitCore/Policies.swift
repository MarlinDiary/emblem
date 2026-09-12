import Foundation
public enum PortraitPolicy {
    public static func qualityScore(width: Int, height: Int, vector: Bool) -> Int { 0 }
    public static func mayDelete(createdByApp: Bool, imageMatches: Bool, historyUnchanged: Bool) -> Bool { false }
}
