import AppKit

_ = FrosttyCLIForwarder.forwardActionIfPresent()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
