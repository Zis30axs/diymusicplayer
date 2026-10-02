import SwiftUI
import UIKit
import SigmaMusicKit

/// Pictures already decoded, kept for the whole launch: a row that scrolls back into view shows its cover on
/// the first frame instead of flashing the placeholder while the bytes are read again.
@MainActor
enum DecodedImages {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    static func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    static func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }

    static func clear() {
        cache.removeAllObjects()
    }
}

/// A square cover (or a round avatar): the picture once it has loaded, a quiet placeholder before that
/// and when there is none. Pictures come through the app's `ImageStore`: kept in memory and on disk.
struct Artwork: View {
    @Environment(AppModel.self) private var app
    let url: String?
    let side: CGFloat
    var symbol = "music.note"
    var round = false

    @State private var loaded: UIImage?

    var body: some View {
        // NetEase resizes on its server: ask for about what the screen can show.
        let source = url.flatMap { NeteaseApi.imageURL($0, side: max(64, Int(side * 2.5))) }
        let shown = loaded ?? source.flatMap { DecodedImages.image(for: $0) }
        ZStack {
            Rectangle().fill(.secondary.opacity(0.22))
            Image(systemName: symbol)
                .font(.system(size: side * 0.42))
                .foregroundStyle(.secondary)
            if let shown {
                Image(uiImage: shown).resizable().scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: side * 0.16)))
        .task(id: source) { await load(source) }
    }

    private func load(_ source: URL?) async {
        guard let source else {
            loaded = nil
            return
        }
        if let ready = DecodedImages.image(for: source) {
            loaded = ready
            return
        }
        guard let data = await app.images.data(for: source), let image = UIImage(data: data) else { return }
        DecodedImages.store(image, for: source)
        loaded = image
    }
}
