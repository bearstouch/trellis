import Foundation

/// The workspace folder a launch uses instead of its identity's Application Support folder, if any.
public enum LaunchStateDirectory {
    public static func resolve(arguments: [String], temporaryDirectory: URL, uniqueName: () -> String = { UUID().uuidString }) -> URL? {
        if let index = arguments.firstIndex(of: "--state-directory"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        // A fixture demo never opens or saves the developer's workspace, and always starts from an empty one.
        if arguments.contains("--fixture") { return temporaryDirectory.appendingPathComponent("trellis-fixture-\(uniqueName())", isDirectory: true) }
        return nil
    }
}
