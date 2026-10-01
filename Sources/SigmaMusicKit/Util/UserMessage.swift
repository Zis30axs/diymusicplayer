import Foundation

/// A short Chinese sentence for an error, for the screen (instead of `localizedDescription`'s English or
/// framework wording). Says what to do when there is something to do.
public func userMessage(for error: any Error) -> String {
    if let service = error as? MusicServiceError {
        switch service {
        case .http(let status, _):
            switch status {
            case 403: return "被服务器拒绝了（403）"
            case 404: return "找不到这个资源（404）"
            case 429: return "请求太频繁，稍后再试（429）"
            case 500...599: return "服务器出错了，稍后再试（\(status)）"
            default: return "服务器返回了 \(status)"
            }
        case .malformedResponse:
            return "服务器返回了无法识别的内容"
        case .rejected(let code):
            switch code {
            case 301: return "需要登录（301）"
            case -460, 460: return "请求被网易云的风控拦下了，稍后再试（\(code)）"
            default: return "网易云拒绝了请求（\(code)）"
            }
        case .invalidTrack:
            return "这首歌不是网易云的歌曲"
        case .offline:
            return "当前没有联网的音乐来源"
        }
    }
    if let download = error as? DownloadError {
        switch download {
        case .preview: return "只有试听片段，登录 VIP 账号后才能下载全曲"
        case .unavailable: return "网易云没有这首歌的音频"
        case .incomplete: return "下载的文件不完整，请重试"
        }
    }
    if let url = error as? URLError {
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "没有网络连接，检查 Wi-Fi 或蜂窝网络"
        case .timedOut:
            return "网络超时，请重试"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "连不上服务器，稍后再试"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return "安全连接失败"
        case .cancelled:
            return "已取消"
        default:
            break
        }
    }
    let text = (error as NSError).localizedDescription
    return text.isEmpty ? String(describing: error) : text
}
