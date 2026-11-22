import SwiftUI
import NaddafCore

@main
struct NaddafApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Naddaf \(NaddafInfo.version)")
                .padding(40)
        }
    }
}
