import Foundation
import Testing
@testable import BanyanCore

@Test func supervisorOutputBurstKeepsOneDeadlineWithoutReadingFleetCadence() {
    let schedule = SessionSupervisorTickSchedule()
    let start = Date(timeIntervalSince1970: 1000)
    var cadenceReads = 0
    func fleetCadence() -> TimeInterval {
        cadenceReads += 1
        return 30
    }
    var scheduledFire: Date?
    var replacements = 0
    // Thousands of chunks from one or many sessions still need only one wakeup.
    for chunk in 0..<5000 {
        if let fire = schedule.replacementFire(
            at: start.addingTimeInterval(Double(chunk) / 5000),
            scheduledFire: scheduledFire,
            activityPending: true,
            interval: fleetCadence()
        ) {
            scheduledFire = fire
            replacements += 1
        }
    }
    #expect(cadenceReads == 0)
    #expect(replacements == 1)
    #expect(scheduledFire == start.addingTimeInterval(2))
}

@Test func supervisorActivityAdvancesBackoffAndPreservesEarlierDeadline() {
    let schedule = SessionSupervisorTickSchedule()
    let now = Date(timeIntervalSince1970: 1000)
    #expect(schedule.replacementFire(
        at: now, scheduledFire: now.addingTimeInterval(30), activityPending: true, interval: 300
    ) == now.addingTimeInterval(2))
    #expect(schedule.replacementFire(
        at: now, scheduledFire: now.addingTimeInterval(1), activityPending: true, interval: 300
    ) == nil)
}

@Test func supervisorInFlightActivityDefersCadenceReadsAndRespectsCompletionRest() {
    var schedule = SessionSupervisorTickSchedule()
    let now = Date(timeIntervalSince1970: 1000)
    var cadenceReads = 0
    func fleetCadence() -> TimeInterval {
        cadenceReads += 1
        return 30
    }
    let began = schedule.begin()
    #expect(began)
    for activityPending in [true, false] {
        #expect(schedule.replacementFire(
            at: now, scheduledFire: nil, activityPending: activityPending, interval: fleetCadence()
        ) == nil)
    }
    #expect(cadenceReads == 0)
    schedule.finish(at: now, minimumRest: 6)
    #expect(schedule.replacementFire(
        at: now, scheduledFire: nil, activityPending: true, interval: fleetCadence()
    ) == now.addingTimeInterval(6))
    #expect(cadenceReads == 0)
}

@Test func supervisorQuietSchedulingStillUsesAdaptiveFleetCadence() {
    let schedule = SessionSupervisorTickSchedule()
    let now = Date(timeIntervalSince1970: 1000)
    var cadenceReads = 0
    func fleetCadence() -> TimeInterval {
        cadenceReads += 1
        return 30
    }
    #expect(schedule.replacementFire(
        at: now, scheduledFire: nil, activityPending: false, interval: fleetCadence()
    ) == now.addingTimeInterval(30))
    #expect(cadenceReads == 1)
}
