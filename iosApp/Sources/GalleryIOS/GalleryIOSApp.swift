import SwiftUI
import GoogleSignIn

@main
struct GalleryIOSApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
        .onOpenURL { url in
          GIDSignIn.sharedInstance.handle(url)
        }
    }
  }
}
