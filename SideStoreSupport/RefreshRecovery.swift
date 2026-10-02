import Foundation

/// Objective-C entry points avoid linking the optional support framework into
/// the standalone host UI. The explicit host path avoids guest defaults/home.
@objc(LCRefreshRecovery)
public final class RefreshRecovery: NSObject {
    static func makeJournal() throws -> RefreshTaskJournal {
        guard let pointer = getenv("LC_HOME_PATH"),
              let home = String(validatingUTF8: pointer), !home.isEmpty else {
            throw NSError(domain: "LCRefreshRecovery", code: 1)
        }
        return RefreshTaskJournal(directory: URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/LiveContainerRefresh", isDirectory: true))
    }

    @objc public static func recoverOnLaunch() {
        DispatchQueue.main.async { _ = snapshot() }
    }

    @objc public static func snapshot() -> NSDictionary {
        do {
            let record = try makeJournal().recoverAndRead()
            let attempt = record.active ?? record.lastCompletion?.attempt
            var value: [String: Any] = ["status": record.active?.stage.rawValue ?? record.lastCompletion?.outcome.rawValue ?? "idle"]
            if let attempt {
                value["taskID"] = attempt.taskID
                value["startedAt"] = attempt.startedAt.timeIntervalSince1970
                value["stage"] = attempt.stage.rawValue
            }
            if record.active == nil, let completion = record.lastCompletion {
                value["finishedAt"] = completion.finishedAt.timeIntervalSince1970
            }
            return value as NSDictionary
        } catch {
            return ["status": "unavailable"] as NSDictionary
        }
    }
}
