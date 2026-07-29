import BanyanCore

extension SessionListAction {
    init(byte: UInt8) {
        switch byte {
        case 113: self = .quit       // q
        case 104: self = .toggleHistory // h
        case 47: self = .searchHistory // /
        case 106: self = .next       // j
        case 107: self = .previous   // k
        case 114: self = .refresh    // r
        case 82: self = .recover     // R
        case 110: self = .newSession // n
        case 78: self = .newCustomSession // N
        case 101: self = .rename // e
        case 99: self = .close       // c
        case 120: self = .remove     // x
        case 10, 13: self = .activate // return
        case 84: self = .trimResume  // T
        default: self = .unknown
        }
    }

    init(sequence: [UInt8]) {
        switch sequence {
        case [27, 91, 65]: self = .previous // up
        case [27, 91, 66]: self = .next // down
        case [27, 91, 53, 126]: self = .pagePrevious // page up
        case [27, 91, 54, 126]: self = .pageNext // page down
        default: self = sequence.count == 1 ? SessionListAction(byte: sequence[0]) : .unknown
        }
    }
}
