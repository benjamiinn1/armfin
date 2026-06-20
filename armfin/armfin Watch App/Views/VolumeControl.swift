import SwiftUI
import WatchKit

/// Digital Crown volume control. Uses `WKInterfaceVolumeControl` via
/// `WKInterfaceObjectRepresentable`. The focus call is delayed to avoid
/// conflicts with view lifecycle during initial appearance.
struct VolumeControl: View {
    var body: some View {
        VolumeControlRepresentable()
    }
}

private struct VolumeControlRepresentable: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: .local)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak control] in
            control?.focus()
        }
        return control
    }

    func updateWKInterfaceObject(_ wkInterfaceObject: WKInterfaceVolumeControl, context: Context) {
    }
}
