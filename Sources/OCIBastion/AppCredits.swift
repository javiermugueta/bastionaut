import AppKit

/// Autoría: código original de Israel y mejoras de Javier Mugueta.
enum AppCredits {
    static let originalAuthor = "Israel (israelgoracle)"
    static let originalRepository = URL(string: "https://github.com/israelgoracle/OCIBastion_MacOs")!
    static let improvementsBy = "Javier Mugueta"

    @MainActor
    static func showAboutPanel() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        credits.append(NSAttributedString(string: String(localized: "Autor original: \(originalAuthor)") + "\n", attributes: body))
        credits.append(NSAttributedString(string: String(localized: "Mejoras: \(improvementsBy)") + "\n\n", attributes: body))
        var link = body
        link[.link] = originalRepository
        credits.append(NSAttributedString(string: String(localized: "Código original en GitHub"), attributes: link))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
