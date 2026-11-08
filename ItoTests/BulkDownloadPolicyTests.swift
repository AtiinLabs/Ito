import Combine
import Foundation
import Testing
@testable import Ito

/// One row of the admission table in the offline-chapters design (§4.2). Named so a failing row
/// reports which path it covers.
nonisolated struct BulkDownloadAdmissionRow: Sendable, CustomTestStringConvertible {
    let name: String
    let path: NetworkPathSnapshot
    let expected: BulkDownloadAdmission

    var testDescription: String { name }
}

struct BulkDownloadPolicyTests {
    static let admissionTable: [BulkDownloadAdmissionRow] = [
        BulkDownloadAdmissionRow(
            name: "unknown path waits for a reading",
            path: NetworkPathSnapshot(status: .unknown),
            expected: .wait(.networkUnknown)
        ),
        BulkDownloadAdmissionRow(
            name: "unknown path with expensive and constrained flags still waits for a reading",
            path: NetworkPathSnapshot(status: .unknown, isExpensive: true, isConstrained: true),
            expected: .wait(.networkUnknown)
        ),
        BulkDownloadAdmissionRow(
            name: "unsatisfied path has no connection",
            path: NetworkPathSnapshot(status: .unsatisfied),
            expected: .wait(.noConnection)
        ),
        BulkDownloadAdmissionRow(
            name: "unsatisfied path with expensive and constrained flags has no connection",
            path: NetworkPathSnapshot(status: .unsatisfied, isExpensive: true, isConstrained: true),
            expected: .wait(.noConnection)
        ),
        BulkDownloadAdmissionRow(
            name: "requires-connection path has no connection",
            path: NetworkPathSnapshot(status: .requiresConnection),
            expected: .wait(.noConnection)
        ),
        BulkDownloadAdmissionRow(
            name: "requires-connection path with expensive flag has no connection",
            path: NetworkPathSnapshot(status: .requiresConnection, isExpensive: true),
            expected: .wait(.noConnection)
        ),
        BulkDownloadAdmissionRow(
            name: "satisfied expensive path is metered",
            path: NetworkPathSnapshot(status: .satisfied, isExpensive: true),
            expected: .wait(.meteredNetwork)
        ),
        BulkDownloadAdmissionRow(
            name: "satisfied constrained path is low data mode",
            path: NetworkPathSnapshot(status: .satisfied, isConstrained: true),
            expected: .wait(.lowDataMode)
        ),
        BulkDownloadAdmissionRow(
            name: "satisfied expensive and constrained path is metered, the stricter reason",
            path: NetworkPathSnapshot(status: .satisfied, isExpensive: true, isConstrained: true),
            expected: .wait(.meteredNetwork)
        ),
        BulkDownloadAdmissionRow(
            name: "satisfied unmetered unconstrained path is allowed",
            path: NetworkPathSnapshot(status: .satisfied),
            expected: .allow
        )
    ]

    @Test(arguments: BulkDownloadPolicyTests.admissionTable)
    func admissionMatchesTheTable(_ row: BulkDownloadAdmissionRow) {
        #expect(BulkDownloadPolicy.admit(row.path) == row.expected)
    }

    @Test func admissionFollowsPathUpdatesFromTheObserver() {
        let observer = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))
        var admissions: [BulkDownloadAdmission] = []
        var cancellables = Set<AnyCancellable>()
        observer.updates
            .map { BulkDownloadPolicy.admit($0) }
            .sink { admissions.append($0) }
            .store(in: &cancellables)

        // The subscriber first replays the unmetered path. Switching to an expensive path
        // mid-download reports metered, a repeated expensive report is suppressed, and returning
        // to an unmetered path is admitted again.
        observer.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        observer.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        observer.set(NetworkPathSnapshot(status: .satisfied))

        #expect(admissions == [.allow, .wait(.meteredNetwork), .allow])
        #expect(BulkDownloadPolicy.admit(observer.current) == .allow)
    }
}
