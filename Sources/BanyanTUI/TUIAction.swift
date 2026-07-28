enum TUIAction {
    case quit
    case toggleHistory
    case next
    case previous
    case refresh
    case recover
    case newSession
    case close
    case remove
    case activate
    case trimResume
    case unknown

    init(byte: UInt8) {
        switch byte {
        case 113: self = .quit       // q
        case 104: self = .toggleHistory // h
        case 106: self = .next       // j
        case 107: self = .previous   // k
        case 114: self = .refresh    // r
        case 82: self = .recover     // R
        case 110: self = .newSession // n
        case 99: self = .close       // c
        case 120: self = .remove     // x
        case 10, 13: self = .activate // return
        case 84: self = .trimResume  // T
        default: self = .unknown
        }
    }
}
