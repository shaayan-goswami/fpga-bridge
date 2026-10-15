import FPGABridgeCore
import SwiftUI

/// A rounded panel used on the Project Summary, in the style of macOS System Settings.
struct Card<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, symbol: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                Text(title).font(.headline)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

/// A small coloured capsule: "Timing met", "Out-of-date", "Top".
struct Pill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Label/value rows aligned like a macOS inspector.
struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.callout)
    }
}

struct ResourceBar: View {
    let usage: ResourceUsage

    private var color: Color {
        usage.percent >= 90 ? .red : usage.percent >= 70 ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(usage.kind.rawValue).font(.callout.weight(.medium))
                Spacer()
                Text("\(formatCount(usage.used)) / \(Int(usage.available).formatted())")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f%%", usage.percent))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color.gradient)
                        .frame(width: max(5, geo.size.width * min(1, usage.percent / 100)))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Run status icon: a spinner while running, otherwise the status symbol.
struct RunStatusIcon: View {
    let state: RunState

    var body: some View {
        if state.status == .running {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: state.symbol).foregroundStyle(state.color)
        }
    }
}

/// Colours for console lines.
extension ConsoleLine.Kind {
    var color: Color {
        switch self {
        case .command: .accentColor
        case .output: .primary
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }

    var symbol: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        default: "chevron.right"
        }
    }
}
