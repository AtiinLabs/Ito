@testable import Ito

extension PluginManager {
    /// Seeds the published plugin state for a test that runs no plugin-directory operation. Production
    /// publication goes through the directory gate; a test that seeds state before starting one doesn't need it.
    @MainActor
    func publishPreparedInstalledPlugins(_ installedPlugins: [String: InstalledPlugin]) {
        publishPreparedInstalledPluginsLocked(installedPlugins, PluginDirectoryLease())
    }
}
