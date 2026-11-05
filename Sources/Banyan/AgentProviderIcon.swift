import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers


/// VS Code–style split "+" control for a project header: the primary action
/// spawns the project's last-used session kind, and the dropdown picks another
/// (remembering it). The icon reflects the remembered kind, so it becomes the
/// Claude/Codex logo once one of those is chosen.
struct ProjectNewSessionButton: View {
    @EnvironmentObject private var store: SessionStore
    let groupID: String
    let groupTitle: String

    var body: some View {
        // Time-of-use pricing flips at most a few times a day, so a
        // once-a-minute refresh is sufficient to keep the pricing help fresh.
        // Polling here is unavoidable: there is no push source for wall-clock
        // pricing boundaries.
        TimelineView(.everyMinute) { context in
            let current = store.projectLaunch(for: groupID)
            Menu {
                ForEach(store.sessionLaunchProfiles) { launch in
                    Button {
                        store.spawnSession(inProjectGroup: groupID, launch: launch)
                    } label: {
                        Label {
                            Text(launch.label)
                        } icon: {
                            launch.menuIconImage
                        }
                    }
                }
            } label: {
                NewSessionLaunchIcon(launch: current)
            } primaryAction: {
                store.spawnSession(inProjectGroup: groupID, launch: current)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .banyanButtonHoverEffect()
            .help(peakAwareHelp(for: current, at: context.date))
            .accessibilityIdentifier(AccessibilityID.projectAddSession(groupID))
        }
    }

    private func peakAwareHelp(for launch: NewSessionLaunch, at date: Date) -> String {
        let base = "New \(launch.label) session in \(groupTitle)"
        guard let provider = launch.provider,
              let pricing = PeakPricingPolicy.helpText(for: provider, at: date)
        else {
            return base
        }
        return "\(base)\n\(pricing)"
    }
}

struct NewSessionLaunchIcon: View {
    let launch: NewSessionLaunch
    var size: CGFloat = 14

    var body: some View {
        if let customIconImage = launch.customIconImage {
            Image(nsImage: customIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else if let provider = launch.provider, launch.usesProviderIcon {
            AgentProviderIcon(provider: provider, size: size)
        } else {
            Image(systemName: launch.systemImage)
                .font(.caption)
                .frame(width: size, height: size)
        }
    }
}

struct AgentProviderIcon: View {
    let provider: CodingAgentProvider
    var size: CGFloat = 20
    var helpText: String? = nil
    /// Closed/history rows show a past session, so peak-*now* would mislead.
    /// Pass false there; live rows and the picker leave it true.
    var showsPeakBadge: Bool = true

    var body: some View {
        if showsPeakBadge, PeakPricingPolicy.hasTimeSensitivePricing(provider) {
            // Same once-a-minute rationale as the picker: pricing boundaries
            // are wall-clock events with no push source.
            TimelineView(.everyMinute) { context in
                iconStack(at: context.date)
            }
        } else {
            iconStack(at: Date())
        }
    }

    private func iconStack(at date: Date) -> some View {
        baseIcon
            .overlay(alignment: .bottomTrailing) {
                if PeakPricingPolicy.isPeak(at: date, for: provider) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: peakDotDiameter, height: peakDotDiameter)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 1.5)
                        )
                        .accessibilityLabel("Peak pricing")
                }
            }
            .frame(width: size, height: size)
            .help(combinedHelp(at: date))
    }

    private var peakDotDiameter: CGFloat {
        max(6, size * 0.38)
    }

    private func combinedHelp(at date: Date) -> String {
        let base = helpText ?? provider.displayName
        guard let pricing = PeakPricingPolicy.helpText(for: provider, at: date) else {
            return base
        }
        if base == pricing { return pricing }
        return "\(base)\n\(pricing)"
    }

    private var baseIcon: some View {
        Group {
            if let modelIcon = modelIcon {
                Image(nsImage: modelIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else if let templateIcon = templateIcon {
                Image(nsImage: templateIcon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
                    .frame(width: size * 0.9, height: size * 0.9)
            } else if let appIcon = installedAppIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.9, height: size * 0.9)
            } else {
                Text(provider.badgeText)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size * 0.9, height: size * 0.8)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }
        }
    }

    private var modelIcon: NSImage? {
        guard let resourceName = modelIconResourceName,
              let url = Bundle.module.url(forResource: resourceName, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return provider == .codex ? codexColorIcon : nil
        }
        image.size = NSSize(width: 20, height: 20)
        return image
    }

    private var modelIconResourceName: String? {
        switch provider {
        case .claude:
            return "ClaudeLogo"
        case .codex:
            return "ChatGPTLogo"
        case .deepseek:
            return "DeepSeekLogo"
        case .gemini:
            return "GeminiLogo"
        case .hunyuan:
            return "HunyuanLogo"
        case .minimax:
            return "MiniMaxLogo"
        case .muse:
            return "MuseLogo"
        case .opencode:
            return nil
        case .qwen:
            return "QwenLogo"
        case .xiaomiMiMo:
            return "XiaomiMiMoLogo"
        case .zai:
            return "ZAILogo"
        }
    }

    private var codexColorIcon: NSImage? {
        guard provider == .codex else { return nil }
        for path in codexColorIconPaths where FileManager.default.fileExists(atPath: path) {
            guard let image = NSImage(contentsOfFile: path),
                  let cropped = cropCodexInnerMark(from: image)
            else {
                continue
            }
            return cropped
        }
        return nil
    }

    private var templateIcon: NSImage? {
        guard provider == .codex else { return nil }
        for path in codexTemplatePaths where FileManager.default.fileExists(atPath: path) {
            guard let image = NSImage(contentsOfFile: path) else { continue }
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
    }

    private func cropCodexInnerMark(from image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let side = min(cgImage.width, cgImage.height)
        let cropSize = Int(Double(side) * 0.72)
        let originX = (cgImage.width - cropSize) / 2
        let originY = Int(Double(cgImage.height - cropSize) * 0.48)
        let cropRect = CGRect(x: originX, y: originY, width: cropSize, height: cropSize)
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }
        return NSImage(cgImage: cropped, size: NSSize(width: 20, height: 20))
    }

    private var installedAppIcon: NSImage? {
        for path in candidateAppPaths where FileManager.default.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 18, height: 18)
            return icon
        }
        return nil
    }

    private var codexTemplatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png",
            "/Applications/Codex.app/Contents/Resources/codexTemplate.png",
            "\(home)/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png",
            "\(home)/Applications/Codex.app/Contents/Resources/codexTemplate.png"
        ]
    }

    private var codexColorIconPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/Applications/Codex.app/Contents/Resources/icon-codex-dark-color.png",
            "/Applications/Codex.app/Contents/Resources/icon-codex-light.png",
            "\(home)/Applications/Codex.app/Contents/Resources/icon-codex-dark-color.png",
            "\(home)/Applications/Codex.app/Contents/Resources/icon-codex-light.png"
        ]
    }

    private var candidateAppPaths: [String] {
        let home = NSHomeDirectory()
        switch provider {
        case .claude:
            return [
                "/Applications/Claude.app",
                "\(home)/Applications/Claude.app"
            ]
        case .codex:
            return [
                "/Applications/Codex.app",
                "\(home)/Applications/Codex.app"
            ]
        case .deepseek:
            return [
                "/Applications/DeepSeek.app",
                "\(home)/Applications/DeepSeek.app"
            ]
        case .gemini, .hunyuan, .minimax, .muse, .qwen, .xiaomiMiMo, .zai:
            return []
        case .opencode:
            return [
                "/Applications/OpenCode.app",
                "\(home)/Applications/OpenCode.app"
            ]
        }
    }
}
