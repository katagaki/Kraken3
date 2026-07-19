#if os(macOS)
import AppKit

setlinebuf(stdout)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
#else
runHeadless()
#endif
