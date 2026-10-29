import Foundation

/// The JSON history (per-minute day files, activity-today.json, baseline.json) was replaced by `HealthDB`.
public enum LegacyHistory {
    /// Deletes the obsolete `history/` folder under `support`. Returns whether anything was removed.
    @discardableResult
    public static func removeObsoleteFiles(in support: URL) -> Bool {
        let dir = support.appendingPathComponent("history", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        return (try? FileManager.default.removeItem(at: dir)) != nil
    }
}
