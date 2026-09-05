import SwiftUI
import UIKit

/// Renders the mock's rect/circle/text SVG subset without allocating a WebView.
struct RemoteArtwork: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack { Color.secondary.opacity(0.15); Image(systemName: "person.crop.square") }
            }
        }
        .clipped()
        .task(id: url) {
            image = nil
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                image = UIImage(data: data) ?? MockSVGArtwork.render(data)
            } catch { image = nil }
        }
    }
}

@MainActor enum MockSVGArtwork {
    static func render(_ data: Data) -> UIImage? {
        let parser = XMLParser(data: data)
        let delegate = Elements()
        parser.delegate = delegate
        guard parser.parse(), let background = delegate.background,
              let foreground = delegate.foreground, !delegate.text.isEmpty else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { context in
            color(background).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
            color(foreground).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 24, y: 24, width: 192, height: 192))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 96), .foregroundColor: color(background)
            ]
            let text = delegate.text as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (240 - size.width) / 2, y: 152 - 96),
                      withAttributes: attributes)
        }
    }

    private static func color(_ hex: String) -> UIColor {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    private final class Elements: NSObject, XMLParserDelegate {
        var background: String?
        var foreground: String?
        var text = ""
        private var readingText = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            if elementName == "rect" { background = attributeDict["fill"] }
            if elementName == "circle" { foreground = attributeDict["fill"] }
            readingText = elementName == "text"
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if readingText { text += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "text" { readingText = false }
        }
    }
}
