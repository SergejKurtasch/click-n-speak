import AppKit

// Menu-bar (accessory) app: no Dock icon, no main menu bar app. When packaged,
// Info.plist sets LSUIElement; when run as a raw executable during development
// we set the activation policy programmatically so behaviour matches.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
