import AppKit

let app = NSApplication.shared
let delegate = AppDelegate(bundle: .main)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
