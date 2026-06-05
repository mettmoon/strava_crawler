import Foundation

struct Credentials: Sendable {
    var cookie: String
    var csrfToken: String

    static let empty = Credentials(cookie: "", csrfToken: "")
}
