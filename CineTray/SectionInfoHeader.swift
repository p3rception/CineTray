import SwiftUI

/// A section header label with a trailing info button that opens a popover
/// showing the section's description text. Used in settings views to replace
/// verbose footer text with an on-demand popover.
struct SectionInfoHeader: View {
    let title: String
    let info: String
    @State private var showingInfo = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Button("Info", systemImage: "info.circle") {
                showingInfo.toggle()
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showingInfo, arrowEdge: .trailing) {
                Text(info)
                    .padding()
                    .frame(width: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
