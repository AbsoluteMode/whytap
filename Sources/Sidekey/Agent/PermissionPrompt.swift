import Foundation

struct PermissionPrompt: Equatable, Identifiable {
    let id: String          // == control_request request_id
    let toolName: String
    let summary: String
    let inputJSON: String    // echoed on allow
}
