import AppKit

let launchMode = LaunchMode(arguments: ProcessInfo.processInfo.arguments)
let app = NSApplication.shared
app.setActivationPolicy(launchMode == .background ? .accessory : .regular)
let delegate = AppDelegate(launchMode: launchMode)
app.delegate = delegate
app.run()
