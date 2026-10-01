import SwiftUI
import SigmaMusicKit

/// A square cover (or a round avatar): the picture once it has loaded, a quiet placeholder before that
/// and when there is none.
struct Artwork: View {
    let url: String?
    let side: CGFloat
    var symbol = "music.note"
    var round = false

    var body: some View {
        // NetEase resizes on its server: ask for about what the screen can show.
        let source = url.flatMap { NeteaseApi.imageURL($0, side: max(64, Int(side * 2.5))) }
        ZStack {
            Rectangle().fill(.secondary.opacity(0.22))
            Image(systemName: symbol)
                .font(.system(size: side * 0.42))
                .foregroundStyle(.secondary)
            if let source {
                AsyncImage(url: source) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: side * 0.16)))
    }
}
