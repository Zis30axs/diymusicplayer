import SwiftUI
import SigmaMusicKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var steps: [NetworkCheck.Step] = Demo.screen == "settings-net" ? Demo.networkSteps : []
    @State private var checking = false

    var body: some View {
        @Bindable var settings = app
        List {
            Section("歌词") {
                Picker("来源", selection: $settings.lyricChannel) {
                    Text("混合（推荐）").tag(LyricsService.Channel.mix)
                    Text("QQ 音乐").tag(LyricsService.Channel.qq)
                    Text("网易云").tag(LyricsService.Channel.netease)
                }
                Picker("显示", selection: $settings.lyricMode) {
                    Text("自动").tag(LyricsService.Mode.auto)
                    Text("逐行").tag(LyricsService.Mode.line)
                    Text("只要逐词").tag(LyricsService.Mode.word)
                }
                Picker("附带", selection: $settings.lyricLanguage) {
                    Text("原文").tag(LyricsService.Language.original)
                    Text("译文").tag(LyricsService.Language.translation)
                    Text("音译").tag(LyricsService.Language.romanization)
                    Text("只看译文").tag(LyricsService.Language.translationOnly)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Stepper(value: $settings.lyricDelayMs, in: -1000...1000, step: 50) {
                        Text("延迟 \(app.lyricDelayMs) 毫秒")
                    }
                    Text("歌词比声音早，就加大")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Section("声音") {
                Picker("音质", selection: $settings.audioQuality) {
                    Text("标准 128k").tag(NeteaseApi.StreamQuality.standard)
                    Text("较高 320k").tag(NeteaseApi.StreamQuality.high)
                }
                Text("网慢或常卡顿，就用标准")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Picker("输出", selection: $settings.outputMode) {
                    Text("自动").tag(OutputMode.automatic)
                    Text("耳机").tag(OutputMode.headphones)
                    Text("扬声器").tag(OutputMode.speaker)
                }
                Text("息屏和后台播放只在蓝牙耳机上有效")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("网络") {
                Button {
                    Task { await runCheck() }
                } label: {
                    if checking {
                        HStack(spacing: 6) { ProgressView(); Text("测速中…") }
                    } else {
                        Text(steps.isEmpty ? "测速" : "再测一次")
                    }
                }
                .disabled(checking || app.netease == nil)
                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(step.name).font(.caption2)
                            Spacer(minLength: 4)
                            Text(step.millis.map { "\($0) 毫秒" } ?? "失败")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(step.millis == nil ? Color.red : Color.secondary)
                        }
                        if !step.detail.isEmpty {
                            Text(step.detail).font(.system(size: 10)).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("设置")
    }

    private func runCheck() async {
        checking = true
        steps = []
        let result = await NetworkCheck(netease: app.netease).run()
        steps = result
        checking = false
    }
}
