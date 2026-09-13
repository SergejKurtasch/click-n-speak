import sys
import re

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

# Disable the menu item if canRevert is false across all languages.
# Since we don't have configuredLanguages here easily, we can use dictionaryCoordinator?.snapshot.prompt_snapshots keys

# Let's see how the menu is built.
