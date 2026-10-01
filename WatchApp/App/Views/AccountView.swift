import SwiftUI
import SigmaMusicKit

/// Signing in to NetEase by QR code: scan the code on the watch with the NetEase app on a phone.
struct AccountView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false

    var body: some View {
        let account = app.account
        let state = account.state
        ScrollView {
            VStack(spacing: 8) {
                switch state.phase {
                case .signedIn:
                    signedIn(account)
                case .waiting, .scanned:
                    if let text = state.qrText {
                        QRView(text: text)
                        if state.phase == .scanned {
                            Text("已扫码\(state.scanner.map { "：\($0)" } ?? "")，请在手机上确认")
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("用网易云音乐 App 扫一扫").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Button("取消") { account.cancelLogin() }
                        .font(.caption)
                case .fetching:
                    ProgressView("获取二维码…")
                case .idle, .expired, .denied, .failed:
                    signedOut(account, state: state)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("网易云")
        .onDisappear {
            if account.state.phase != .signedIn { account.cancelLogin() }
        }
    }

    @ViewBuilder
    private func signedIn(_ account: NeteaseAccount) -> some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 36))
            .foregroundStyle(.tint)
        if let profile = account.profile {
            Text(profile.nickname).font(.headline).lineLimit(1)
            Text(profile.vip ? "VIP 会员" : "非 VIP")
                .font(.caption2)
                .foregroundStyle(profile.vip ? Color.orange : Color.secondary)
        } else {
            Text("已登录").font(.headline)
        }
        Button("退出登录", role: .destructive) { confirmSignOut = true }
            .confirmationDialog("退出网易云登录？", isPresented: $confirmSignOut) {
                Button("退出登录", role: .destructive) { Task { await account.signOut() } }
            }
    }

    @ViewBuilder
    private func signedOut(_ account: NeteaseAccount, state: NeteaseAccount.State) -> some View {
        if state.lapsed {
            Text("登录已过期，请重新扫码").font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
        }
        switch state.phase {
        case .expired:
            Text("二维码已过期").font(.caption).foregroundStyle(.secondary)
        case .denied:
            Text("网易云拒绝了这次登录（安全验证）").font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
        case .failed:
            Text("没能完成登录，检查网络后重试").font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
        default:
            Text("登录后可听 VIP 歌曲全曲、看每日推荐和歌单")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        Button(state.phase == .expired ? "刷新二维码" : "扫码登录") { account.startLogin() }
    }
}
