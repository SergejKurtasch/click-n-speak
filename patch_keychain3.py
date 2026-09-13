with open("Packages/CNSCore/Sources/CNSCore/KeychainHelper.swift", "r") as f:
    content = f.read()

content = content.replace("private static func setRawKeychainPassword", "public static func setRawKeychainPassword")
content = content.replace("private static func deleteRawKeychainPassword", "public static func deleteRawKeychainPassword")

with open("Packages/CNSCore/Sources/CNSCore/KeychainHelper.swift", "w") as f:
    f.write(content)
