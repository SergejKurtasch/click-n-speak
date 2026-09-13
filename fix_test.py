import sys

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "r") as f:
    content = f.read()

setup = """    override func setUp() {
        super.setUp()
        
        let config = Config()
        let i18n = FakeI18n()
        let resources = AppResources(bundle: .module, appDataPath: "/tmp/clicknspeak-test-ui")
        let paths = FakeAppPaths()
        let permissionService = FakePermissionService()
        
        sut = MenuBarController(
            config: config,
            i18n: i18n,
            resources: resources,
            paths: paths,
            permissionService: permissionService,
            phraseHistory: nil,
            dictionaryCoordinator: nil,
            installStatusItem: false
        )
    }"""
content = content.replace("""    override func setUp() {
        super.setUp()
        sut = MenuBarController()
    }""", setup)

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "w") as f:
    f.write(content)
