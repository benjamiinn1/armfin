import SwiftUI

/// The category dropdown plus an optional circular shuffle button on the
/// same row — one easy-to-hit target instead of a full-width "Shuffle All"
/// row underneath the list. The button only appears when the caller has
/// something to shuffle (the Songs category, when it's non-empty).
///
/// `alignment: .top` matters here: `CategoryDropdownPicker` grows downward
/// when expanded, and without it the shuffle circle would recenter itself
/// against that taller height instead of staying pinned beside the
/// collapsed dropdown button.
struct CategoryPickerBar<Tab: Hashable & RawRepresentable & CaseIterable>: View where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    var shuffleAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CategoryDropdownPicker(selection: $selection)

            if let shuffleAction {
                Button(action: shuffleAction) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.blue, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle All")
            }
        }
    }
}
