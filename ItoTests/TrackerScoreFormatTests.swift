import Foundation
import Testing
@testable import Ito

@MainActor
struct TrackerScoreFormatTests {
    @Test(arguments: ["en_US", "fr_FR", "ar_EG"])
    func numericRatingsRoundTripNativeDigitsAndDecimalSeparators(localeID: String) {
        let locale = Locale(identifier: localeID)
        let style = TrackerScoreFormat.numericStyle.locale(locale)
        for value in [0.0, 0.125, 85.5, 90.55, 100] {
            let text = style.format(value)
            #expect(TrackerScoreFormat.parseNumericScore(text, locale: locale) == value)
        }
    }

    @Test(arguments: ["", ".", "85oops", "90,5", "1.2.3", "-1", "101", "NaN", "inf", "1e2"])
    func numericRatingsRejectInvalidWholeInput(text: String) {
        #expect(TrackerScoreFormat.parseNumericScore(text, locale: Locale(identifier: "en_US")) == nil)
    }

    @Test func numericRatingsAcceptFractionsWithoutRelaxingIntegerScales() {
        #expect(TrackerScoreFormat.numeric100.isValid(85.5))
        #expect(TrackerScoreFormat.numeric100.isValid(0))
        #expect(TrackerScoreFormat.numeric100.isValid(100))
        #expect(!TrackerScoreFormat.numeric100.isValid(-1))
        #expect(!TrackerScoreFormat.numeric100.isValid(100.01))
        #expect(!TrackerScoreFormat.numeric100.isValid(.nan))
        #expect(!TrackerScoreFormat.numeric100.isValid(.infinity))
        #expect(!TrackerScoreFormat.point100.isValid(85.5))
        #expect(!TrackerScoreFormat.point10.isValid(8.5))
    }
}
