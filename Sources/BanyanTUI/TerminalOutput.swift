import Foundation

protocol TUIOutput {
    func write(_ text: String, terminator: String)
}

struct StandardTUIOutput: TUIOutput {
    func write(_ text: String, terminator: String = "\n") {
        FileHandle.standardOutput.write(Data((text + terminator).utf8))
    }
}
