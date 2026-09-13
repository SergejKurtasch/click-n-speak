import sys

with open("Packages/CNSCore/Sources/CNSCore/ModelDownloader.swift", "r") as f:
    content = f.read()

# add registry to properties
content = content.replace("private let metadataInspector: any ArtifactMetadataInspecting", "private let registry: ModelArtifactAccessRegistry\n    private let metadataInspector: any ArtifactMetadataInspecting")

# add to init
content = content.replace("        paths: Paths,\n        metadataInspector: any ArtifactMetadataInspecting = URLSessionArtifactMetadataInspector(),", "        paths: Paths,\n        registry: ModelArtifactAccessRegistry = .shared,\n        metadataInspector: any ArtifactMetadataInspecting = URLSessionArtifactMetadataInspector(),")
content = content.replace("self.paths = paths\n        self.metadataInspector = metadataInspector", "self.paths = paths\n        self.registry = registry\n        self.metadataInspector = metadataInspector")

# add tokens to properties
content = content.replace("private var generation = 0", "private var accessTokens: [UUID] = []\n    private var generation = 0")

with open("Packages/CNSCore/Sources/CNSCore/ModelDownloader.swift", "w") as f:
    f.write(content)
