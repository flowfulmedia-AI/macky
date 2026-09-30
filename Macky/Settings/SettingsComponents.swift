import SwiftUI

// Building blocks for Macky's settings: pages with a title, labelled groups of rows in dark cards,
// and controls that match the rest of Macky.

/// A settings page: big title, a sentence under it, then its groups.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(MackyDesign.rounded(28, .bold))
                        .foregroundColor(MackyDesign.textPrimary)
                    Text(subtitle)
                        .font(MackyDesign.rounded(14))
                        .foregroundColor(MackyDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A labelled card of rows. Put `SettingsDivider()` between rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(MackyDesign.rounded(11, .bold))
                    .tracking(1.3)
                    .foregroundColor(MackyDesign.textSecondary)
                    .padding(.leading, 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
            )
            if let footer {
                Text(footer)
                    .font(MackyDesign.rounded(12))
                    .foregroundColor(MackyDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// One setting: a title and an explanation on the left, its control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MackyDesign.rounded(14, .semibold))
                    .foregroundColor(MackyDesign.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(MackyDesign.rounded(12))
                        .foregroundColor(MackyDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// Free-form content inside a group (lists, text fields, instructions).
struct SettingsBlock<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(MackyDesign.hairline)
            .frame(height: 1)
            .padding(.leading, 18)
    }
}

/// Numbered setup steps, e.g. how to create a Google or Zoom app.
struct SettingsSteps: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(MackyDesign.rounded(11, .bold))
                        .foregroundColor(Color(red: 0.08, green: 0.10, blue: 0.25))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(MackyDesign.primaryButtonGradient))
                    Text(step)
                        .font(MackyDesign.rounded(13))
                        .foregroundColor(MackyDesign.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// "Conectat" / "Neconectat" with a colored dot.
struct StatusBadge: View {
    let isOn: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(isOn ? MackyDesign.accent : Color.white.opacity(0.3)).frame(width: 8, height: 8)
            Text(text).font(MackyDesign.rounded(12, .semibold)).foregroundColor(isOn ? MackyDesign.textPrimary : MackyDesign.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(MackyDesign.surface))
        .overlay(Capsule().stroke(MackyDesign.hairline, lineWidth: 1))
    }
}

/// A status or error line under a control.
struct SettingsMessage: View {
    let text: String
    var isError: Bool {
        let lowercased = text.lowercased()
        return text.hasPrefix("✗") || lowercased.hasPrefix("eroare") || lowercased.contains("eșuat") || lowercased.contains("nu am putut")
            || lowercased.contains("nu are voie") || lowercased.contains("nu găsesc")
    }

    var body: some View {
        Text(text)
            .font(MackyDesign.rounded(12))
            .foregroundColor(isError ? .orange : MackyDesign.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The light-blue capsule switch with a dark knob.
struct MackyToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(MackyDesign.primaryButtonGradient) : AnyShapeStyle(Color.white.opacity(0.14)))
                    .overlay(Capsule().stroke(configuration.isOn ? MackyDesign.primaryButtonGlow.opacity(0.9) : MackyDesign.hairline, lineWidth: 1.2))
                    .shadow(color: configuration.isOn ? MackyDesign.primaryButtonGlow.opacity(0.45) : .clear, radius: 6)
                Circle()
                    .fill(configuration.isOn ? Color.black : Color.white.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .padding(3)
            }
            .frame(width: 46, height: 26)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
            .pointingHandOnHover()
        }
    }
}

extension View {
    /// Dark rounded text field.
    func mackyField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(MackyDesign.rounded(13))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
    }

    /// A compact menu picker aligned to the right of a row.
    func settingsMenu() -> some View {
        self
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
    }
}
