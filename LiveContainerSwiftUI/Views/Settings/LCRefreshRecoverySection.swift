import SwiftUI

struct LCRefreshRecoverySection: View {
    let status: [String: Any]

    private var name: String { status["status"] as? String ?? "idle" }

    var body: some View {
        Section {
            Text(("lc.refresh.status." + name).loc)
            if let timestamp = status["startedAt"] as? Double {
                HStack {
                    Text("lc.refresh.status.started".loc)
                    Spacer()
                    Text(Date(timeIntervalSince1970: timestamp), format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("lc.refresh.status.title".loc)
        } footer: {
            if name == "interrupted" {
                Text("lc.refresh.status.interruptedDetail".loc)
            } else if name == "unavailable" {
                Text("lc.refresh.status.unavailableDetail".loc)
            }
        }
    }
}
