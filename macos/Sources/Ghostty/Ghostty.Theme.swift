import Foundation

extension Ghostty {
    /// Ghostty's theme files, found where the config's `theme` finds them: booTTY's
    /// `themes` directory in the XDG config home first, then the themes bundled with the app.
    enum Theme {
        /// The directories themes come from, in lookup order.
        static var directories: [URL] {
            let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".config")
            return [
                configHome.appendingPathComponent("bootty/themes", isDirectory: true),
                Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes", isDirectory: true),
            ].compactMap { $0 }
        }

        /// The file of theme `name`, or nil when no directory has one.
        static func url(named name: String) -> URL? {
            directories.lazy
                .map { $0.appendingPathComponent(name, isDirectory: false) }
                .first { FileManager.default.isReadableFile(atPath: $0.path) }
        }

        /// Every theme's name, sorted as Finder sorts names. A user theme and a bundled one
        /// of the same name are one theme, as the lookup finds the user's.
        static func names() -> [String] {
            let files = directories.flatMap { directory in
                (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: .skipsHiddenFiles)) ?? []
            }
            let names = files
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map(\.lastPathComponent)
            return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}
