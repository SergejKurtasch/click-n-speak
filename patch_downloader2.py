import sys

with open("Packages/CNSCore/Sources/CNSCore/ModelDownloader.swift", "r") as f:
    content = f.read()

# in start(model: ModelInfo)
old_start = """    public func start(model: ModelInfo) {
        guard state != .downloading, state != .validating else {
            log("ModelDownloader: another model operation is active")
            return
        }
        generation += 1"""
new_start = """    public func start(model: ModelInfo) {
        guard state != .downloading, state != .validating else {
            log("ModelDownloader: another model operation is active")
            return
        }
        generation += 1
        let currentGeneration = generation
        let taskID = UUID()
        if let token = try? registry.acquireUse(modelID: model.id, reason: .downloading(taskID: taskID)) {
            accessTokens.append(token)
        } else {
            // "If damaged model is retained by active service, safely reject replacement until released"
            applyError("Model currently in use and cannot be replaced", generation: currentGeneration)
            return
        }"""
content = content.replace(old_start, new_start)

# in invalidateTransferSession
old_invalidate = """    private func invalidateTransferSession() {
        transferGeneration += 1
        dataTask = nil"""
new_invalidate = """    private func invalidateTransferSession() {
        for token in accessTokens {
            registry.releaseUse(token)
        }
        accessTokens.removeAll()
        transferGeneration += 1
        dataTask = nil"""
content = content.replace(old_invalidate, new_invalidate)

# in deinit
old_deinit = """    deinit {
        session?.invalidateAndCancel()
    }"""
new_deinit = """    deinit {
        session?.invalidateAndCancel()
        for token in accessTokens {
            registry.releaseUse(token)
        }
    }"""
content = content.replace(old_deinit, new_deinit)

with open("Packages/CNSCore/Sources/CNSCore/ModelDownloader.swift", "w") as f:
    f.write(content)
