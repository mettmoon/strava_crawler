import Foundation
import CourseBoyKit

struct FetchMyRoutesUseCase: Sendable {
    let remoteService: any StravaRemoteService
    let credentialsProvider: @Sendable () -> Credentials

    func execute(after: String = "0", pageSize: Int = 16) async throws -> MyRoutesPage {
        var creds = credentialsProvider()
        if creds.csrfToken.isEmpty {
            creds.csrfToken = try await remoteService.fetchCSRFToken(credentials: creds)
            AppSettings.csrfToken = creds.csrfToken
        }
        return try await remoteService.fetchMyRoutes(
            after: after, pageSize: pageSize, credentials: creds
        )
    }
}
