import SwiftUI
import NaddafCore

@main
struct NaddafApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Naddaf \(NaddafCore.version)")
                .padding(40)
        }
    }
}
