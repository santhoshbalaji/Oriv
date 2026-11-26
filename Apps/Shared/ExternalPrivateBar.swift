import SwiftUI
import BrowserCore

struct ExternalPrivateBar: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(macOS)
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    #endif
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
        #if os(iOS)
        content
            .font(OrivType.detail)
            .padding(OrivSpacing.medium)
            .background(theme.privateWash, in: RoundedRectangle(cornerRadius: OrivRadius.card))
            .padding(.horizontal, OrivSpacing.large)
            .padding(.vertical, OrivSpacing.small)
        #else
        macHandoffBar
        #endif
    }

    #if os(iOS)
    @ViewBuilder private var content: some View {
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
    }

    private func actions(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: OrivSpacing.small))
                             : AnyLayout(HStackLayout(spacing: OrivSpacing.small))
        return layout { picker; moveButton }
    }

    private var title: some View {
        OrivBannerLabel(message: message, tone: .privateBrowsing, symbol: "eyeglasses")
            .accessibilityIdentifier("externalPrivateNotice")
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
                    .padding(.horizontal, OrivSpacing.medium).padding(.vertical, OrivSpacing.small)
                    .frame(minHeight: targetSize)
            }
            .orivButton(.accentFill)
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

    private var targetSize: CGFloat { 44 }
    #else
    private var macContrast: ColorSchemeContrast { captureContrast ?? systemContrast }
    private var macIncreasedContrast: Bool { macContrast == .increased }
    private var macSolid: Bool {
        OrivMacV3.usesOpaqueSurface(theme: theme, reduceTransparency: reduceTransparency,
                                    captureReduceTransparency: captureReduceTransparency, contrast: macContrast)
    }
    private var macAccessibleSolid: Bool {
        reduceTransparency || captureReduceTransparency || macIncreasedContrast || theme.isT3Code
    }

    private var macHandoffBar: some View {
        ViewThatFits(in: .horizontal) {
            macHandoffPill(horizontalInset: OrivMacV3.ToolbarLayout.handoffHorizontalInset,
                           spacing: OrivMacV3.ToolbarLayout.handoffGap,
                           minLabelWidth: nil, idealLabelWidth: nil,
                           compactMove: false, compactKeep: false)
            macHandoffPill(horizontalInset: OrivMacV3.ToolbarLayout.paddingHorizontal,
                           spacing: OrivMacV3.ToolbarLayout.handoffMediumGap,
                           minLabelWidth: OrivMacV3.ToolbarLayout.handoffMessageMinWidth,
                           idealLabelWidth: OrivMacV3.ToolbarLayout.handoffMessageIdealWidth,
                           compactMove: false, compactKeep: false)
            // Narrow windows truncate the source label first; buttons keep their
            // full labels until the label is already at its compact minimum.
            macHandoffPill(horizontalInset: OrivMacV3.ToolbarLayout.paddingHorizontal,
                           spacing: OrivMacV3.ToolbarLayout.handoffCompactGap,
                           minLabelWidth: OrivMacV3.ToolbarLayout.handoffCompactMessageMinWidth,
                           idealLabelWidth: OrivMacV3.ToolbarLayout.handoffCompactMessageIdealWidth,
                           compactMove: false, compactKeep: false)
            macHandoffPill(horizontalInset: OrivMacV3.ToolbarLayout.paddingHorizontal,
                           spacing: OrivMacV3.ToolbarLayout.handoffCompactGap,
                           minLabelWidth: OrivMacV3.ToolbarLayout.handoffCompactMessageMinWidth,
                           idealLabelWidth: OrivMacV3.ToolbarLayout.handoffCompactMessageIdealWidth,
                           compactMove: false, compactKeep: true)
            macHandoffPill(horizontalInset: OrivMacV3.ToolbarLayout.paddingHorizontal,
                           spacing: OrivMacV3.ToolbarLayout.handoffCompactGap,
                           minLabelWidth: .zero, idealLabelWidth: .zero,
                           compactMove: true, compactKeep: true)
        }
        .padding(.top, OrivMacV3.ToolbarLayout.handoffTopGap)
        .padding(.bottom, OrivMacV3.ToolbarLayout.handoffBottomGap)
    }

    private func macHandoffPill(horizontalInset: CGFloat, spacing: CGFloat,
                                minLabelWidth: CGFloat?, idealLabelWidth: CGFloat?,
                                compactMove: Bool, compactKeep: Bool) -> some View {
        let barShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.pageCard, style: .continuous)
        return HStack(spacing: spacing) {
            if let minLabelWidth, let idealLabelWidth {
                macNotice
                    .frame(minWidth: minLabelWidth, idealWidth: idealLabelWidth, maxWidth: .infinity, alignment: .leading)
            } else {
                macNotice
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            macPicker.fixedSize()
            if canMove {
                macMoveButton(compact: compactMove).fixedSize()
            }
            macKeepButton(compact: compactKeep).fixedSize()
        }
        .padding(.leading, OrivMacV3.ToolbarLayout.handoffLeadingPadding)
        .padding(.trailing, OrivMacV3.ToolbarLayout.handoffTrailingPadding)
        .frame(maxWidth: .infinity)
        .frame(minHeight: OrivMacV3.ToolbarLayout.handoffHeight,
               maxHeight: typeSize.isAccessibilitySize ? nil : OrivMacV3.ToolbarLayout.handoffHeight)
        .orivV3Glass(OrivMacV3.Handoff.bar, in: barShape)
        .orivV3Shadow(OrivMacV3.Handoff.shadow)
        .focusSection()
        .browserGeometryMarker("externalPrivateBarGeometry")
        .padding(.horizontal, horizontalInset)
    }

    private var macNotice: some View {
        HStack(spacing: OrivSpacing.small) {
            Image(systemName: "eyeglasses")
                .font(OrivIcon.toolbarFont)
                .foregroundStyle(OrivMacV3.Semantic.privateAccent(.private, increasedContrast: macIncreasedContrast))
                .accessibilityHidden(true)
            Text(macNoticeAttributed)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.tail)
        }
        .browserGeometryMarker("externalPrivateNoticeGeometry")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier("externalPrivateNotice")
    }

    private var macNoticeAttributed: AttributedString {
        var base = AttributeContainer()
        base.font = OrivMacV3.Typography.handoffMessage
        base.foregroundColor = OrivMacV3.Handoff.messageForeground(increasedContrast: macIncreasedContrast)
        guard let sourceName, !sourceName.isEmpty else {
            return AttributedString("Opened privately", attributes: base)
        }
        var result = AttributedString("Opened privately from ", attributes: base)
        var emphasis = AttributeContainer()
        emphasis.font = OrivMacV3.Typography.handoffAppName
        emphasis.foregroundColor = OrivMacV3.Ink.primary(.private)
        result.append(AttributedString(sourceName, attributes: emphasis))
        return result
    }

    private var macPicker: some View {
        let shape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous)
        return Menu {
            Picker("Destination profile", selection: $selection) {
                ForEach(profiles) { Label($0.name, systemImage: $0.symbol.rawValue).tag($0.id) }
            }
        } label: {
            HStack(spacing: OrivMacV3.ToolbarLayout.handoffPickerInnerGap) {
                Circle()
                    .fill(OrivMacV3.Sidebar.profileDotFill(selectedProfile?.color ?? .mulberry, mode: .private))
                    .frame(width: OrivMacV3.ToolbarLayout.handoffPickerDotSize,
                           height: OrivMacV3.ToolbarLayout.handoffPickerDotSize)
                    .accessibilityHidden(true)
                Text(selectedName)
                    .font(OrivMacV3.Typography.detail)
                    .foregroundStyle(OrivMacV3.Ink.primary(.private))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(OrivMacV3.Typography.suggestionAlreadyOpenArrow)
                    .foregroundStyle(OrivMacV3.Ink.secondary(.private, increasedContrast: macIncreasedContrast))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, OrivMacV3.ToolbarLayout.handoffPickerPaddingHorizontal)
            .frame(height: OrivMacV3.ToolbarLayout.handoffControlHeight)
            .background(OrivMacV3.Handoff.pickerSurface(solid: macSolid), in: shape)
            .overlay {
                shape.strokeBorder(
                    OrivMacV3.Handoff.pickerOutline(increasedContrast: macIncreasedContrast),
                    lineWidth: macIncreasedContrast ? OrivOutline.enhanced : OrivOutline.hairline
                )
            }
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .browserGeometryMarker("externalMoveProfileGeometry")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Destination profile")
        .accessibilityValue(selectedName)
        .accessibilityHint("Choose the profile to move this page to")
        .accessibilityIdentifier("externalMoveProfile")
    }

    private func macMoveButton(compact: Bool) -> some View {
        Button(action: move) {
            Text(compact ? "Move" : "Move to \(selectedName)")
                .font(OrivMacV3.Typography.detailSemibold)
                .foregroundStyle(OrivMacV3.Handoff.moveButtonInk)
                .lineLimit(1)
                .padding(.horizontal, OrivMacV3.ToolbarLayout.handoffMovePaddingHorizontal)
                .frame(height: OrivMacV3.ToolbarLayout.handoffControlHeight)
                .contentShape(RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous))
        }
        .buttonStyle(MacHandoffMoveButtonStyle(solid: macAccessibleSolid, increasedContrast: macIncreasedContrast))
        .browserGeometryMarker("moveExternalPageGeometry")
        // No defaultAction shortcut: Return in the address field or page must never move a private page.
        .accessibilityLabel("Move to \(selectedName)")
        .accessibilityHint("Opens this address in \(selectedName) and closes its private tab")
        .accessibilityIdentifier("moveExternalPage")
    }

    private func macKeepButton(compact: Bool) -> some View {
        Button(action: dismiss) {
            HStack(spacing: OrivMacV3.ToolbarLayout.handoffDismissInnerGap) {
                if !compact {
                    Text("Keep Private")
                        .font(OrivMacV3.Typography.detail)
                        .lineLimit(1)
                }
                Image(systemName: "xmark")
                    .font(OrivMacV3.Typography.suggestionAlreadyOpenArrow)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(OrivMacV3.Handoff.keepForeground(increasedContrast: macIncreasedContrast))
            .padding(.horizontal, OrivMacV3.ToolbarLayout.handoffDismissPaddingHorizontal)
            .frame(minWidth: OrivMacV3.ToolbarLayout.handoffControlHeight,
                   minHeight: OrivMacV3.ToolbarLayout.handoffControlHeight,
                   maxHeight: OrivMacV3.ToolbarLayout.handoffControlHeight)
            .contentShape(RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous))
        }
        .buttonStyle(MacHandoffKeepButtonStyle(increasedContrast: macIncreasedContrast))
        .browserGeometryMarker("keepExternalPrivateGeometry")
        .accessibilityLabel("Keep Private")
        .accessibilityHint("Dismisses this notice and keeps the page in private browsing")
        .accessibilityIdentifier("keepExternalPrivate")
    }
    #endif
}

#if os(macOS)
private struct MacHandoffMoveButtonStyle: ButtonStyle {
    let solid: Bool
    let increasedContrast: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, solid: solid, increasedContrast: increasedContrast)
    }

    private struct Face: View {
        @Environment(\.browserReduceMotion) private var reduceMotion
        let configuration: Configuration
        let solid: Bool
        let increasedContrast: Bool
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous)
            configuration.label
                .background {
                    if solid {
                        shape.fill(OrivMacV3.Handoff.moveButtonSolid)
                    } else {
                        shape.fill(OrivMacV3.Handoff.moveButtonGradient)
                    }
                }
                .overlay {
                    if configuration.isPressed {
                        shape.fill(OrivMacV3.Handoff.moveButtonPressedOverlay).allowsHitTesting(false)
                    } else if hovered {
                        shape.fill(OrivMacV3.Handoff.moveButtonHoverOverlay).allowsHitTesting(false)
                    }
                }
                .overlay {
                    if increasedContrast {
                        shape.strokeBorder(OrivMacV3.Card.rimIncreasedContrast(.private), lineWidth: OrivOutline.enhanced)
                            .allowsHitTesting(false)
                    } else if !solid {
                        shape.inset(by: OrivOutline.hairline)
                            .stroke(
                                LinearGradient(colors: [OrivMacV3.Handoff.moveButtonSpecularTop, .clear],
                                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25)),
                                lineWidth: OrivOutline.hairline * 2
                            )
                            .allowsHitTesting(false)
                    }
                }
                .animation(OrivMacV3.Motion.quick(reduceMotion: reduceMotion), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

private struct MacHandoffKeepButtonStyle: ButtonStyle {
    let increasedContrast: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, increasedContrast: increasedContrast)
    }

    private struct Face: View {
        @Environment(\.browserReduceMotion) private var reduceMotion
        let configuration: Configuration
        let increasedContrast: Bool
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous)
            configuration.label
                .background {
                    if configuration.isPressed {
                        shape.fill(OrivMacV3.Handoff.dismissPressedFill)
                    } else if hovered {
                        shape.fill(OrivMacV3.Handoff.dismissHoverFill)
                    }
                }
                .overlay {
                    if increasedContrast && (hovered || configuration.isPressed) {
                        shape.strokeBorder(OrivMacV3.Card.rimIncreasedContrast(.private), lineWidth: OrivOutline.hairline)
                            .allowsHitTesting(false)
                    }
                }
                .animation(OrivMacV3.Motion.quick(reduceMotion: reduceMotion), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}
#endif
