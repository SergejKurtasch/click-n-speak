import sys

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "r") as f:
    content = f.read()

setup = """    override func setUp() {
        super.setUp()
        
        let resources = repoResources()
        let i18n = I18n.load("en", localesDirectory: resources.localesDirectory)
        let config = Config()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cns-menu-tests-\\(UUID().uuidString)")
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        
        sut = MenuBarController(
            config: config,
            i18n: i18n,
            resources: resources,
            paths: paths,
            installStatusItem: false
        )
    }"""
    
import re
content = re.sub(r'    override func setUp\(\) \{[\s\S]*?installStatusItem: false\n        \)\n    \}', setup, content)

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "w") as f:
    f.write(content)

