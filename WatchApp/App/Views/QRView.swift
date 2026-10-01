import SwiftUI
import SigmaMusicKit

/// A QR code on white with the four-module quiet zone the standard asks for.
struct QRView: View {
    let text: String

    var body: some View {
        if let code = try? QRCode(encoding: text) {
            Canvas { context, size in
                let quiet = 4
                let modules = code.size + 2 * quiet
                let side = min(size.width, size.height)
                let unit = side / CGFloat(modules)
                context.fill(Path(CGRect(x: 0, y: 0, width: side, height: side)), with: .color(.white))
                var dark = Path()
                for y in 0..<code.size {
                    for x in 0..<code.size where code.isDark(x: x, y: y) {
                        // A hair of overlap so no seams show between neighbouring modules.
                        dark.addRect(CGRect(
                            x: CGFloat(x + quiet) * unit,
                            y: CGFloat(y + quiet) * unit,
                            width: unit + 0.4,
                            height: unit + 0.4
                        ))
                    }
                }
                context.fill(dark, with: .color(.black))
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("登录二维码")
        } else {
            Text("二维码生成失败").font(.caption)
        }
    }
}
