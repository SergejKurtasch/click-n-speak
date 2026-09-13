with open("Packages/CNSCore/Sources/CNSCore/KeychainHelper.swift", "r") as f:
    content = f.read()

content = content.replace("private static func getRawKeychainPassword", "public static func getRawKeychainPassword")

with open("Packages/CNSCore/Sources/CNSCore/KeychainHelper.swift", "w") as f:
    f.write(content)
