import AppKit

// No storyboard, no nib, no XIB loading: the app is up as soon as AppKit is.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
AppDelegate.shared = delegate
app.run()
