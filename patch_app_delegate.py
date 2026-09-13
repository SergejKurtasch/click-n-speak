import sys

with open("ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift", "r") as f:
    content = f.read()

old_cb = """        menuCtrl.onConfigurationReloaded = { [weak self, weak runtimeCoordinator, weak dictionaryCoordinator] updated in
            guard let self, let dictionaryCoordinator else { return }
            let previousPrimary = dictionaryCoordinator.snapshot.primaryLanguage
            try dictionaryCoordinator.adoptPersistedConfiguration(updated)"""
new_cb = """        menuCtrl.onConfigurationReloaded = { [weak self, weak runtimeCoordinator, weak dictionaryCoordinator] updated in
            guard let self, let dictionaryCoordinator else { return }
            _ = try updated.recordingSettings
            let previousPrimary = dictionaryCoordinator.snapshot.primaryLanguage
            try dictionaryCoordinator.adoptPersistedConfiguration(updated)"""
content = content.replace(old_cb, new_cb)

with open("ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift", "w") as f:
    f.write(content)
