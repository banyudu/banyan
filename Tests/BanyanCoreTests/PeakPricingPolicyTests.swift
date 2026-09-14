import Foundation
import Testing
@testable import BanyanCore

private func beijingCalendar() -> Calendar {
    PeakPricingPolicy.beijingCalendar
}

private func beijingDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0
    let date = beijingCalendar().date(from: components)!
    return date
}

@Test func deepSeekPeakWindowsOnWeekdays() {
    let calendar = beijingCalendar()
    // Monday 2026-08-24.
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 8, 59), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 9, 0), calendar: calendar) == true)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 11, 59), calendar: calendar) == true)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 12, 0), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 12, 30), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 13, 59), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 14, 0), calendar: calendar) == true)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 17, 59), calendar: calendar) == true)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 18, 0), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 23, 0), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 24, 0, 30), calendar: calendar) == false)
}

@Test func deepSeekWeekendsAreAlwaysOffPeak() {
    let calendar = beijingCalendar()
    // Saturday 2026-08-29 and Sunday 2026-08-30: even inside weekday windows.
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 29, 10, 0), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 29, 15, 0), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 30, 10, 0), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 30, 15, 0), calendar: calendar) == false)
    // Friday 17:59 is the last peak minute; Monday 09:00 reopens it.
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 28, 17, 59), calendar: calendar) == true)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 28, 18, 0), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 31, 8, 59), calendar: calendar) == false)
    #expect(PeakPricingPolicy.isDeepSeekPeak(at: beijingDate(2026, 8, 31, 9, 0), calendar: calendar) == true)
}

@Test func deepSeekWeekdayIsReadOnBeijingCalendar() {
    // 2026-08-28T16:30Z is Saturday 00:30 Beijing (weekend) — off-peak.
    let fridayUTC = Date(timeIntervalSince1970: 1787934600) // 2026-08-28T16:30:00Z
    #expect(PeakPricingPolicy.isPeak(at: fridayUTC, for: .deepseek) == false)
    // 2026-08-30T16:30Z is Monday 00:30 Beijing (night) — off-peak.
    let sundayUTC = Date(timeIntervalSince1970: 1788107400) // 2026-08-30T16:30:00Z
    #expect(PeakPricingPolicy.isPeak(at: sundayUTC, for: .deepseek) == false)
}

@Test func onlyDeepSeekHasTimeSensitivePricing() {
    #expect(PeakPricingPolicy.hasTimeSensitivePricing(.deepseek) == true)
    #expect(PeakPricingPolicy.hasTimeSensitivePricing(.claude) == false)
    #expect(PeakPricingPolicy.hasTimeSensitivePricing(.codex) == false)
    #expect(PeakPricingPolicy.tier(for: .claude, at: beijingDate(2026, 8, 24, 10, 0)) == nil)
    #expect(PeakPricingPolicy.tier(for: .deepseek, at: beijingDate(2026, 8, 24, 10, 0)) == .peak)
    #expect(PeakPricingPolicy.tier(for: .deepseek, at: beijingDate(2026, 8, 24, 13, 0)) == .offPeak)
}

@Test func nextTransitionFindsIntradayAndWeekendBoundaries() {
    let calendar = beijingCalendar()
    let fmt = { (d: Date) -> String in
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: d)
        return "\(c.month!)-\(c.day!) \(c.hour!):\(String(format: "%02d", c.minute!))"
    }
    // Monday morning peak → noon off-peak.
    let mon10 = beijingDate(2026, 8, 24, 10, 0)
    #expect(fmt(PeakPricingPolicy.nextTransition(after: mon10, calendar: calendar)!) == "8-24 12:00")
    // Lunch gap → afternoon peak.
    let mon1230 = beijingDate(2026, 8, 24, 12, 30)
    #expect(fmt(PeakPricingPolicy.nextTransition(after: mon1230, calendar: calendar)!) == "8-24 14:00")
    // Friday evening → Monday morning (weekend has no intraday flips).
    let fri19 = beijingDate(2026, 8, 28, 19, 0)
    #expect(fmt(PeakPricingPolicy.nextTransition(after: fri19, calendar: calendar)!) == "8-31 9:00")
    // Saturday midday → Monday morning.
    let sat10 = beijingDate(2026, 8, 29, 10, 0)
    #expect(fmt(PeakPricingPolicy.nextTransition(after: sat10, calendar: calendar)!) == "8-31 9:00")
}
