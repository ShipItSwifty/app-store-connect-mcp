import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("CIDate")
struct CIDateTests {
    @Test("parses ISO-8601 with and without fractional seconds")
    func parsesBothForms() {
        #expect(CIDate.parse("2026-09-01T12:00:00Z") != nil)
        #expect(CIDate.parse("2026-09-01T12:00:00.123Z") != nil)
        #expect(CIDate.parse("2026-09-01T12:00:00+00:00") != nil)
        #expect(CIDate.parse(nil) == nil)
        #expect(CIDate.parse("") == nil)
        #expect(CIDate.parse("not a date") == nil)
    }

    @Test("durationSeconds returns the positive interval, rounded")
    func computesDuration() {
        #expect(
            CIDate.durationSeconds(from: "2026-09-01T12:00:00Z", to: "2026-09-01T14:00:00Z") == 7200)
        #expect(
            CIDate.durationSeconds(from: "2026-09-01T12:00:00.000Z", to: "2026-09-01T12:00:01.500Z") == 2)
    }

    @Test("durationSeconds is nil for missing, unparseable, or negative intervals")
    func rejectsBadInput() {
        #expect(CIDate.durationSeconds(from: nil, to: "2026-09-01T12:00:00Z") == nil)
        #expect(CIDate.durationSeconds(from: "2026-09-01T12:00:00Z", to: nil) == nil)
        #expect(CIDate.durationSeconds(from: "2026-09-01T14:00:00Z", to: "2026-09-01T12:00:00Z") == nil)
    }
}
