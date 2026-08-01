import Foundation

enum ScanMode: String, CaseIterable, Identifiable, Sendable {
    case orphanHunt
    case cacheDiet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orphanHunt: "The Orphan Hunt"
        case .cacheDiet:  "The Cache Diet"
        }
    }

    var subtitle: String {
        switch self {
        case .orphanHunt: "Support files left behind by apps you've already deleted."
        case .cacheDiet:  "Caches and logs belonging to apps you still use."
        }
    }

    var symbol: String {
        switch self {
        case .orphanHunt: "questionmark.folder"
        case .cacheDiet:  "chart.pie"
        }
    }
}
