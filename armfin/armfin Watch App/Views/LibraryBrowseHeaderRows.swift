import SwiftUI

/// The category dropdown + status label pair that opens every browse
/// screen — the Downloads tab and the four Library tabs alike. These were
/// hand-built separately at first and drifted (different padding, the
/// Library tabs missing the label row entirely, the header living outside
/// the list on one side and inside it on the other, which changed how much
/// top clearance each got). This is the one template both now build on top
/// of, as List rows, so they can't drift apart again (soul.md §4.1).
struct LibraryBrowseHeaderRows<Tab: Hashable & RawRepresentable & CaseIterable>: View where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    var shuffleAction: (() -> Void)?
    var statusLabel: String

    var body: some View {
        CategoryPickerBar(selection: $selection, shuffleAction: shuffleAction)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 0, trailing: 8))
            .listRowBackground(Color.clear)

        Text(statusLabel)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.5))
            .frame(height: 14)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowBackground(Color.clear)
    }
}
