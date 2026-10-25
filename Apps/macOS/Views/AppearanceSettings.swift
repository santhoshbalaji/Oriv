import SwiftUI
import BrowserEngine

enum BrowserAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct AppearanceSettings: View {
    @Binding var appearance: BrowserAppearance
    let adBlocker: AdBlocker
    private let runtime = BrowserRuntime.current
    var body: some View {
        TabView {
            appearancePanel.tabItem { Label("Appearance", systemImage: "paintpalette") }
            privacyPanel.tabItem { Label("Privacy", systemImage: "shield.lefthalf.filled") }
            ScrollView { PasswordsGuide() }.tabItem { Label("Passwords", systemImage: "key") }
            aboutPanel.tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16).frame(width: 560, height: 560)
        .background(Theme.canvas).navigationTitle("Oriv Settings")
    }

    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            EditorHeading(title: "Make yourself at home", subtitle: "A quiet space for browsing and thinking.", symbol: "paintpalette")
            HStack(spacing: 12) {
                ForEach(BrowserAppearance.allCases) { choice in
                    Button { appearance = choice } label: {
                        VStack(spacing: 10) {
                            appearancePreview(choice)
                            Text(choice.rawValue).font(.callout.weight(appearance == choice ? .semibold : .regular))
                            Image(systemName: appearance == choice ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(appearance == choice ? Theme.accent : .secondary)
                        }.padding(10).frame(maxWidth: .infinity)
                    }.buttonStyle(ContentButtonStyle()).accessibilityLabel("Use \(choice.rawValue.lowercased()) appearance")
                        .accessibilityAddTraits(appearance == choice ? [.isSelected] : [])
                }
            }
            Text("System follows your Mac. Websites control their own colors. Oriv’s native controls also respect Reduce Transparency, Reduce Motion and Increase Contrast.")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
            Spacer()
        }.padding(24)
    }
    private func appearancePreview(_ choice: BrowserAppearance) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.3)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.2)).frame(height: 4)
                Spacer()
            }.padding(8).frame(width: 36).background(.quaternary)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(.secondary.opacity(0.15)).frame(height: 8)
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.6)).frame(width: 32, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.2)).frame(height: 3)
                Spacer()
            }.padding(8).frame(maxWidth: .infinity)
        }.frame(height: 78).background(Theme.surface).clipShape(.rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator, lineWidth: 0.5) }
            .environment(\.colorScheme, choice == .dark ? .dark : .light).accessibilityHidden(true)
    }
    private var privacyPanel: some View {
        Form {
            Section {
                Picker("Ad blocking", selection: Binding(get: { adBlocker.mode }, set: { adBlocker.setMode($0) })) {
                    ForEach(AdBlockingMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Text(adBlocker.mode.detail).font(.callout).foregroundStyle(.secondary)
                if !adBlocker.regularExceptions.isEmpty {
                    DisclosureGroup("Allowed sites (\(adBlocker.regularExceptions.count))") {
                        ForEach(adBlocker.regularExceptions.sorted(), id: \.self) { host in
                            HStack {
                                Text(host).lineLimit(1)
                                Spacer()
                                Button("Remove") { adBlocker.removeRegularException(host) }
                                    .accessibilityLabel("Remove exception for \(host)")
                            }
                        }
                    }
                }
            } header: { Text("Protection while you browse") } footer: {
                Text("Applies to normal and private tabs. Reload open pages to apply changes fully. Private site exceptions are forgotten when the last private tab closes.")
            }
            Section {
                Label("Page capture happens on your Mac", systemImage: "internaldrive")
                Label("Private pages cannot be captured", systemImage: "eyeglasses")
                Label("Form fields are excluded from captures", systemImage: "text.badge.checkmark")
            } header: { Text("Your saved context") } footer: {
                Text("Your Workspace is stored locally. iCloud sync is not enabled in this version.")
            }
        }.formStyle(.grouped)
    }
    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            OrivIdentity(subtitle: "A place for connected thoughts")
            Text("Keep the context.\nFollow the thought.").font(Theme.editorial(30))
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow { Text("Oriv").foregroundStyle(.secondary); Text("\(runtime.appVersion) (\(runtime.appBuild))") }
                GridRow { Text("macOS").foregroundStyle(.secondary); Text(runtime.operatingSystem) }
                GridRow { Text("WebKit").foregroundStyle(.secondary); Text(runtime.webKitBuild) }
            }.font(.callout).textSelection(.enabled)
            Divider()
            Text("Built with SwiftUI and WebKit. The browser engine is supplied by macOS; install macOS and Safari updates for engine fixes and media support.")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
            Spacer()
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
}
