import SwiftUI

@main
struct CharaTalkApp: App {
    init() {
        Task.detached(priority: .utility) {
            RetiredLocalLLMCleanup.run()
        }
    }

    var body: some Scene {
        WindowGroup {
            if #available(iOS 18.0, *) {
                ContentView()
                    .onOpenURL { url in
                        ChatGPTAuthManager.shared.handleCallback(url: url)
                    }
            } else {
                Text("CharaTalkはiOS 18.0以降のiPhoneでご利用いただけます。")
                    .padding()
            }
        }
    }
}
