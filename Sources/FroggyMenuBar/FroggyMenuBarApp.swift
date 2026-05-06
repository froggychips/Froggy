import SwiftUI
import VortexCore

@main
struct FroggyMenuBarApp: App {
    @StateObject private var model = MenuBarViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
                .frame(width: 360)
        } label: {
            Text(model.menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
