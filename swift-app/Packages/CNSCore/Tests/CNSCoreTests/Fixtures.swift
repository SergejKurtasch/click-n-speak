import Foundation

enum Fixtures {
    static func url(_ relativePath: String) -> URL {
        // Resources copied via `.copy("Fixtures")` keep their directory layout
        // under the module bundle's resource root.
        guard let base = Bundle.module.resourceURL else {
            fatalError("Bundle.module has no resourceURL")
        }
        return base.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
    }

    static func data(_ relativePath: String) -> Data {
        guard let data = try? Data(contentsOf: url(relativePath)) else {
            fatalError("Missing fixture: \(relativePath)")
        }
        return data
    }
}
