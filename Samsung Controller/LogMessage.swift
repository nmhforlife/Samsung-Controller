import Foundation

struct LogMessage: Identifiable, Hashable {
    let id = UUID()
    let message: String
    let timestamp: Date
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: LogMessage, rhs: LogMessage) -> Bool {
        lhs.id == rhs.id
    }
} 