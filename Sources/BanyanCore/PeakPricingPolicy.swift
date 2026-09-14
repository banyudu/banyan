import Foundation

/// Time-of-use pricing for providers with peak/off-peak rates.
///
/// Currently only DeepSeek bills this way: Beijing Mon–Fri 09:00–12:00 and
/// 14:00–18:00 is peak at 2x, everything else (nights, lunch gap, weekends)
/// is off-peak. Weekends are bounded on the vendor clock (Asia/Shanghai).
public enum PeakPricingPolicy {
    public enum Tier: String, Sendable, Equatable {
        case peak
        case offPeak
    }

    /// Vendors with time-sensitive pricing. Keep the logo as identity and
    /// render tier as a separate badge — never recolor brand art.
    public static func hasTimeSensitivePricing(_ provider: CodingAgentProvider) -> Bool {
        provider == .deepseek
    }

    public static var beijingTimeZone: TimeZone {
        TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
    }

    public static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        return calendar
    }

    /// Peak multiplier relative to off-peak (off-peak is half of peak).
    public static let peakMultiplierVsOffPeak = 2.0

    public static func tier(for provider: CodingAgentProvider, at date: Date = Date()) -> Tier? {
        guard hasTimeSensitivePricing(provider) else { return nil }
        return isPeak(at: date, for: provider) ? .peak : .offPeak
    }

    public static func isPeak(at date: Date = Date(), for provider: CodingAgentProvider = .deepseek) -> Bool {
        guard hasTimeSensitivePricing(provider) else { return false }
        return isDeepSeekPeak(at: date, calendar: beijingCalendar)
    }

    /// Core schedule. `calendar` must already be set to Asia/Shanghai;
    /// exposed for deterministic tests.
    public static func isDeepSeekPeak(at date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        // Gregorian: 1 = Sunday … 7 = Saturday. Weekends are off-peak all day.
        guard weekday >= 2, weekday <= 6 else { return false }
        let hour = calendar.component(.hour, from: date)
        // Windows are [09:00, 12:00) and [14:00, 18:00). Hour granularity is
        // sufficient because boundaries fall exactly on the hour.
        if hour >= 9, hour < 12 { return true }
        if hour >= 14, hour < 18 { return true }
        return false
    }

    /// Next pricing boundary after `date` (the instant the tier flips).
    /// Used to render "Peak until 12:00 Beijing" tooltips.
    public static func nextTransition(after date: Date, calendar: Calendar? = nil) -> Date? {
        let calendar = calendar ?? beijingCalendar
        // Scan upcoming day-start + intraday boundaries; 8 days covers
        // Friday-evening → Monday-morning weekend gaps.
        let dayStart = calendar.startOfDay(for: date)
        for dayOffset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: dayStart) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let isWeekday = weekday >= 2 && weekday <= 6
            var candidates: [Date] = []
            if isWeekday {
                for hour in [9, 12, 14, 18] {
                    if let boundary = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) {
                        candidates.append(boundary)
                    }
                }
            }
            // Midnight itself is never a tier flip (off-peak continues across
            // it), so only intraday boundaries matter.
            for candidate in candidates.sorted() where candidate > date {
                return candidate
            }
        }
        return nil
    }

    /// "12:00" in Beijing, for tooltips and badges.
    public static func beijingTimeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = beijingTimeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "DeepSeek · Peak pricing (2x) until 12:00 Beijing" or the off-peak form.
    public static func helpText(for provider: CodingAgentProvider, at date: Date = Date()) -> String? {
        guard hasTimeSensitivePricing(provider) else { return nil }
        let peak = isPeak(at: date, for: provider)
        if let transition = nextTransition(after: date) {
            let time = beijingTimeString(for: transition)
            if peak {
                return "\(provider.displayName) · Peak pricing (2x) until \(time) Beijing"
            }
            return "\(provider.displayName) · Off-peak pricing until \(time) Beijing"
        }
        return peak
            ? "\(provider.displayName) · Peak pricing (2x)"
            : "\(provider.displayName) · Off-peak pricing"
    }
}
