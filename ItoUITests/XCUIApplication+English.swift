import XCTest

extension XCUIApplication {
    /// The app under test, running in English. UI tests find elements by their English
    /// labels, which would otherwise follow the simulator's language.
    static func english(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        return app
    }
}
