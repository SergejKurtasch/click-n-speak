with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

content = content.replace("return KeychainHelper.getPassword(service: s, account: a)", "return KeychainHelper.getRawKeychainPassword(service: s, account: a)")

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
