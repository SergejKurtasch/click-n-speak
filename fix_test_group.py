import sys

with open("Packages/CNSCore/Tests/CNSCoreTests/ModelArtifactAccessTests.swift", "r") as f:
    content = f.read()

old_code = """        let group = DispatchGroup()
        for i in 0..<100 {
            DispatchQueue.global().async(group: group) {
                let token = try? registry.acquireUse(modelID: "model-2", reason: .preparation(generation: i))
                if let token = token {
                    registry.releaseUse(token)
                }
            }
        }
        group.wait()"""
new_code = """        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let token = try? registry.acquireUse(modelID: "model-2", reason: .preparation(generation: i))
                    if let token = token {
                        registry.releaseUse(token)
                    }
                }
            }
        }"""
content = content.replace(old_code, new_code)

with open("Packages/CNSCore/Tests/CNSCoreTests/ModelArtifactAccessTests.swift", "w") as f:
    f.write(content)
