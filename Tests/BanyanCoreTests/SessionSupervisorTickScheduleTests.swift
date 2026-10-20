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

@Test(arguments: [
    (SupervisorActivityLevel.active, false, SupervisorThermalState.nominal, 2.0),
    (.backgroundVisible, false, .nominal, 6.0),
    (.hidden, false, .nominal, 30.0),
    (.hidden, true, .nominal, 60.0),
    (.hidden, false, .serious, 90.0),
])
func continuousOutputRespectsVisibilityAndPower(
    activityLevel: SupervisorActivityLevel,
    lowPower: Bool,
    thermal: SupervisorThermalState,
    expectedInterval: TimeInterval
) {
    var schedule = SessionSupervisorTickSchedule()
    let start = Date(timeIntervalSince1970: 1000)
    var scheduledFire: Date?
    var ticks = 0
    var cadenceReads = 0
    func fleetCadence() -> TimeInterval {
        cadenceReads += 1
        return 300
    }
    let activityInterval = SessionSupervisorCadencePolicy.activityInterval(
        activityLevel: activityLevel, isLowPowerModeEnabled: lowPower, thermalState: thermal
    )

    // Five minutes of continuous PTY traffic, including output during a tick.
    // Hidden traffic used to force 150 inspections instead of at most ten.
    for chunk in 0...30_000 {
        let now = start.addingTimeInterval(Double(chunk) / 100)
        if let deadline = scheduledFire, deadline <= now {
            let began = schedule.begin()
            #expect(began)
            #expect(schedule.replacementFire(
                at: now, scheduledFire: nil, activityPending: true,
                activityInterval: activityInterval, interval: fleetCadence()
            ) == nil)
            ticks += 1
            schedule.finish(at: now, minimumRest: 2)
            scheduledFire = nil
        }
        if let next = schedule.replacementFire(
            at: now, scheduledFire: scheduledFire, activityPending: true,
            activityInterval: activityInterval, interval: fleetCadence()
        ) {
            scheduledFire = next
        }
    }
    #expect(ticks == Int(300 / expectedInterval))
    #expect(cadenceReads == 0)
}

@Test func foregroundActivityAdvancesHiddenDeadline() {
    let schedule = SessionSupervisorTickSchedule()
    let now = Date(timeIntervalSince1970: 1000)
    let hiddenDeadline = schedule.replacementFire(
        at: now, scheduledFire: nil, activityPending: true,
        activityInterval: 30, interval: 300
    )
    #expect(hiddenDeadline == now.addingTimeInterval(30))
    let foreground = now.addingTimeInterval(1)
    #expect(schedule.replacementFire(
        at: foreground, scheduledFire: hiddenDeadline, activityPending: true,
        activityInterval: 2, interval: 6
    ) == foreground.addingTimeInterval(2))
}
