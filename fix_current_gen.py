import sys

with open("Packages/CNSCore/Sources/CNSCore/ModelDownloader.swift", "r") as f:
    content = f.read()

content = content.replace("        let currentGeneration = generation\n        let currentGeneration = generation", "        let currentGeneration = generation")

with open("Packages/CNSCore/Sources/CNSCore/ModelDownloader.swift", "w") as f:
    f.write(content)
