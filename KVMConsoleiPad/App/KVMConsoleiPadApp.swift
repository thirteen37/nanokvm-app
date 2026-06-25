import KVMCore
import SwiftUI

@main
struct KVMConsoleiPadApp: App {
    @StateObject private var devicesStore = SavedDevicesStore()

    var body: some Scene {
        // Connections list. Connecting to a device opens a separate Viewer window
        // (ConnectionManagerView falls back to openWindow(value:) when given no
        // onConnect callback), so two devices can run side-by-side under Stage Manager.
        WindowGroup("KVM Console", id: "connections") {
            NavigationStack {
                ConnectionManagerView()
            }
            .environmentObject(devicesStore)
        }

        // One Viewer window per Device.ID. Wrapped in its own NavigationStack so the
        // viewer's toolbar renders inside the new window rather than the Connections nav.
        WindowGroup("Viewer", id: "viewer", for: Device.ID.self) { $deviceID in
            NavigationStack {
                ViewerHostView(deviceID: deviceID)
            }
            .environmentObject(devicesStore)
        }
    }
}
