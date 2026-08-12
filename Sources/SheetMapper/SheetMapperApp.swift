import SwiftUI

@main
struct SheetMapperApp: App {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent)
        }
            .windowStyle(.titleBar)
            .commands { CommandGroup(replacing: .newItem) { } }
    }
}
