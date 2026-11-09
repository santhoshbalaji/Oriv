import SwiftUI
import BrowserCore

struct ExternalPrivateBar: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let sourceName: String?
    let profiles: [BrowserProfile]
    @Binding var selection: UUID
    let canMove: Bool
    let move: () -> Void
    let dismiss: () -> Void

    private var message: String { sourceName.map { "Opened privately from \($0)" } ?? "Opened privately" }
    private var selectedProfile: BrowserProfile? { profiles.first { $0.id == selection } }
    private var selectedName: String { selectedProfile?.name ?? "Profile" }

    var body: some View {
        content
            #if os(macOS)
            .focusSection()
            #endif
            .font(OrivType.detail)
            .padding(OrivSpacing.medium)
            // Solid surfaces and no animated transitions also respect Reduce Transparency/Motion.
            .background(theme.surface, in: .rect(cornerRadius: OrivRadius.large))
            .padding(.horizontal, OrivSpacing.large)
            .padding(.vertical, OrivSpacing.small)
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: OrivSpacing.small) {
            if typeSize.isAccessibilitySize {
                title
                keepButton
                actions(stacked: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: OrivSpacing.small) { title; Spacer(minLength: 0); keepButton }
                    VStack(alignment: .leading, spacing: OrivSpacing.xs) { title; keepButton }
                }
                ViewThatFits(in: .horizontal) {
                    actions(stacked: false)
                    actions(stacked: true)
                }
            }
        }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OrivSpacing.medium) { title; Spacer(minLength: 0); picker; moveButton; keepButton }
            VStack(alignment: .leading, spacing: OrivSpacing.small) {
                HStack { title; Spacer(minLength: 0); keepButton }
                actions(stacked: false)
            }
        }
        #endif
    }

    private func actions(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: OrivSpacing.small))
                             : AnyLayout(HStackLayout(spacing: OrivSpacing.small))
        return layout { picker; moveButton }
    }

    private var title: some View {
        HStack(spacing: OrivSpacing.small) {
            Image(systemName: "eyeglasses").accessibilityHidden(true)
            Text(message).accessibilityIdentifier("externalPrivateNotice")
        }
        .foregroundStyle(theme.privateAccent)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var picker: some View {
        Menu {
            Picker("Destination profile", selection: $selection) {
                ForEach(profiles) { Label($0.name, systemImage: $0.symbol.rawValue).tag($0.id) }
            }
        } label: {
            HStack(spacing: OrivSpacing.small) {
                Image(systemName: selectedProfile?.symbol.rawValue ?? "person.crop.circle").foregroundStyle(theme.secondaryText).accessibilityHidden(true)
                Text(selectedName).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down").font(OrivType.caption).foregroundStyle(theme.secondaryText).accessibilityHidden(true)
            }
            .padding(.horizontal, OrivSpacing.medium).frame(minHeight: targetSize)
            .background(theme.field, in: .rect(cornerRadius: OrivRadius.small))
            .contentShape(.rect(cornerRadius: OrivRadius.small))
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Destination profile").accessibilityValue(selectedName)
        .accessibilityHint("Choose the profile to move this page to")
        .accessibilityIdentifier("externalMoveProfile")
    }

    @ViewBuilder private var moveButton: some View {
        if canMove {
            Button(action: move) {
                Text("Move to \(selectedName)").font(OrivType.detail.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    #if os(iOS)
                    .padding(.horizontal, OrivSpacing.medium).padding(.vertical, OrivSpacing.small)
                    .frame(minHeight: targetSize)
                    #endif
            }
            #if os(iOS)
            .buttonStyle(ExternalMoveButtonStyle(fill: theme.controlFill))
            #else
            .buttonStyle(.borderedProminent).controlSize(.regular).tint(theme.controlFill)
            // No defaultAction shortcut: Return in the address field or page must never move a private page.
            #endif
            .accessibilityHint("Opens this address in \(selectedName) and closes its private tab")
            .accessibilityIdentifier("moveExternalPage")
        }
    }

    private var keepButton: some View {
        Button(action: dismiss) {
            HStack(spacing: OrivSpacing.xs) {
                Text("Keep Private").fixedSize(horizontal: false, vertical: true)
                Image(systemName: "xmark").font(OrivType.caption).accessibilityHidden(true)
            }.frame(minHeight: targetSize).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
        .accessibilityLabel("Keep Private")
        .accessibilityHint("Dismisses this notice and keeps the page in private browsing")
        .accessibilityIdentifier("keepExternalPrivate")
    }

    private var targetSize: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }
}

#if os(iOS)
private struct ExternalMoveButtonStyle: ButtonStyle {
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .background(fill, in: .rect(cornerRadius: OrivRadius.small))
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}
#endif
