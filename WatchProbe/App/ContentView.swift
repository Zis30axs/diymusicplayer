import SwiftUI

struct ContentView: View {
    @StateObject private var model = ProbeModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("M0 Watch Probe")
                    .font(.headline)

                Text(model.pathStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("HTTPS stream URL", text: $model.urlString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    model.resetExampleURL()
                } label: {
                    Label("Apple HLS preset", systemImage: "arrow.counterclockwise")
                }

                Divider()

                Button {
                    model.testNetwork()
                } label: {
                    Label(
                        model.isTestingNetwork ? "Testing..." : "Test HTTPS",
                        systemImage: "network"
                    )
                }
                .disabled(model.isTestingNetwork)

                Text(model.networkStatus)
                    .font(.footnote)
                    .multilineTextAlignment(.center)

                Divider()

                Toggle("Headphones mode (longFormAudio)", isOn: $model.useLongForm)
                    .font(.caption)

                HStack {
                    Button {
                        model.play()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(model.isStartingPlayback)

                    Button {
                        model.pause()
                    } label: {
                        Image(systemName: "pause.fill")
                    }

                    Button(role: .destructive) {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                }

                Text(model.playbackStatus)
                    .font(.footnote)
                    .multilineTextAlignment(.center)

                Text(model.routeStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.eventLog.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("For the cellular gate, make sure the route label says Cellular before repeating Test HTTPS + Play.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.log("scene: \(String(describing: newPhase))")
        }
        .onChange(of: isLuminanceReduced) { _, reduced in
            model.log(reduced ? "display: dimmed" : "display: bright")
        }
    }
}
