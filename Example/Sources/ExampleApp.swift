import SwiftUI
import PrettySwiftQR

@main
struct ExampleApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                DisplayDemo()
                    .tabItem { Label("Display", systemImage: "qrcode") }
                ScanDemo()
                    .tabItem { Label("Scan", systemImage: "qrcode.viewfinder") }
            }
        }
    }
}
