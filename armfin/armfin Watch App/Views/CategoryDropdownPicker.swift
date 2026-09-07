import SwiftUI

/// Single control that replaces a row of tab buttons for switching between
/// library categories (Artists/Albums/Songs/Genres). `Menu` and
/// `.pickerStyle` are both unavailable on watchOS, so tapping presents the
/// options as a sheet instead of expanding in place — an in-place expansion
/// (four 44pt rows, soul.md §3.4's tap-target floor) was tried first, but on
/// a watch screen it has nowhere to grow: it either overlapped whatever sat
/// below it or pushed the collapsed button itself off past the top edge.
/// A sheet always has the whole screen to itself, so it can't collide with
/// the shuffle button beside it or the content underneath. Shared by the
/// online Library tab and the Downloads tab so the two pickers can't drift
/// apart visually (soul.md §4.1).
struct CategoryDropdownPicker<Tab: Hashable & RawRepresentable & CaseIterable>: View where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(selection.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.white.opacity(0.12), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            optionsList
        }
    }

    private var optionsList: some View {
        List {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                    isPresented = false
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(.system(size: 14, weight: tab == selection ? .semibold : .regular))
                        Spacer()
                        if tab == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(tab == selection ? .white : .white.opacity(0.7))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.black)
    }
}
