import BrowserEngine
import SwiftUI

struct ReaderTextView: View {
    @Environment(\.browserTheme) private var theme
    let capture: PageCapture
    @State private var size: Double = 18
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        OrivSheet(title: "Read page text", size: .large, height: 650) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(capture.title).font(OrivType.title)
                    Text(capture.url.host ?? "").font(.callout).foregroundStyle(theme.secondaryText)
                    Text(capture.text).font(.system(size: size)).lineSpacing(8).textSelection(.enabled)
                    Divider()
                    Text(capture.explanation + " This reading view is temporary and stays on your Mac.").font(.caption).foregroundStyle(theme.secondaryText)
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            Button("Smaller Text", systemImage: "textformat.size.smaller") { size = max(14, size - 2) }.labelStyle(.iconOnly)
            Button("Larger Text", systemImage: "textformat.size.larger") { size = min(30, size + 2) }.labelStyle(.iconOnly)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.background(theme.surface)
    }
}
