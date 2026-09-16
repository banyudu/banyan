import Foundation

struct BenchOptions {
    enum Renderer: String {
        case coreGraphics = "cg"
        case metal
    }

    var renderer: Renderer = .coreGraphics
    /// Bytes of terminal output the measured window replays. Identical for both
    /// arms, so each one performs the same amount of terminal work.
    var bytes = 6 * 1024 * 1024
    var bytesPerSecond = 512 * 1024
    var warmupSeconds = 2.0
    var seed: UInt64 = 79
    /// Mirrors Banyan's adaptive invalidation coalescing. On by default because
    /// the question is what Banyan would ship, not what SwiftTerm does bare.
    var coalesce = true
    var workload = WorkloadGenerator.Kind.stream
    /// Metal only: `perRowPersistent` caches per-row GPU buffers,
    /// `perFrameAggregated` rebuilds one buffer set per frame.
    var metalBuffering = "perRow"
    var json = false
    var width = 1280.0
    var height = 800.0
    var fontSize = 13.0
    /// Emitted verbatim in the JSON so a comparison table can label the run.
    var label: String?

    static func parse(_ arguments: [String]) -> BenchOptions {
        var options = BenchOptions()
        var index = 1
        func value(_ name: String) -> String {
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("missing value for \(name)\n".utf8))
                exit(2)
            }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--renderer":
                let raw = value(argument)
                guard let renderer = Renderer(rawValue: raw) else {
                    FileHandle.standardError.write(Data("unknown renderer '\(raw)' (expected cg or metal)\n".utf8))
                    exit(2)
                }
                options.renderer = renderer
            case "--bytes": options.bytes = Int(value(argument)) ?? options.bytes
            case "--rate": options.bytesPerSecond = Int(value(argument)) ?? options.bytesPerSecond
            case "--warmup": options.warmupSeconds = Double(value(argument)) ?? options.warmupSeconds
            case "--seed": options.seed = UInt64(value(argument)) ?? options.seed
            case "--width": options.width = Double(value(argument)) ?? options.width
            case "--height": options.height = Double(value(argument)) ?? options.height
            case "--font-size": options.fontSize = Double(value(argument)) ?? options.fontSize
            case "--label": options.label = value(argument)
            case "--no-coalesce": options.coalesce = false
            case "--workload":
                let raw = value(argument)
                guard let kind = WorkloadGenerator.Kind(rawValue: raw) else {
                    FileHandle.standardError.write(Data("unknown workload '\(raw)' (expected stream or static)\n".utf8))
                    exit(2)
                }
                options.workload = kind
            case "--metal-buffering":
                let raw = value(argument)
                guard raw == "perRow" || raw == "perFrame" else {
                    FileHandle.standardError.write(Data("unknown buffering '\(raw)' (expected perRow or perFrame)\n".utf8))
                    exit(2)
                }
                options.metalBuffering = raw
            case "--json": options.json = true
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown argument '\(argument)'\n\(usage)\n".utf8))
                exit(2)
            }
            index += 1
        }
        return options
    }

    static let usage = """
    usage: TerminalRenderBench [options]

      --renderer cg|metal   Renderer under test (default cg)
      --bytes N             Bytes of output to replay in the measured window (default 6291456)
      --rate N              Feed rate in bytes per second (default 524288)
      --warmup SECONDS      Unmeasured warmup before the measured window (default 2)
      --seed N              Workload seed; both arms must use the same one (default 79)
      --width/--height PT   Terminal surface size in points (default 1280x800)
      --font-size PT        Terminal font size (default 13)
      --no-coalesce         Drop Banyan's adaptive invalidation coalescing
      --workload stream|static  Scrolling agent output, or in-place alternate-screen repaints (default stream)
      --metal-buffering perRow|perFrame  Metal buffering mode (default perRow)
      --label TEXT          Free-form label echoed into the JSON
      --json                Emit JSON instead of a human summary
    """
}
