import AppKit

extension NSAlert {
    static func reviewWindowsAlert(
        messageText: String,
        informativeText: String = "If you don't review your windows, any running processes will be terminated"
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Review Windows...")
        alert.addButton(withTitle: "Terminate Processes")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        return alert
    }
}
