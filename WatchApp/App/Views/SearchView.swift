import SwiftUI
import SigmaMusicKit

struct SearchView: View {
    @Environment(AppModel.self) private var app

    @State private var query = ""
    @State private var results: ListSource?
    @State private var message = ""
    @State private var searching = false

    var body: some View {
        VStack(spacing: 4) {
            TextField("搜索歌曲或歌手", text: $query)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
            if searching {
                ProgressView()
            } else if let results, !results.tracks.isEmpty {
                TrackRows(source: results)
            } else if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .navigationTitle("搜索")
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        message = ""
        defer { searching = false }
        do {
            let found = try await app.library.search(text)
            results = found
            if found.tracks.isEmpty { message = "没有找到「\(text)」" }
        } catch {
            results = nil
            message = userMessage(for: error)
        }
    }
}
