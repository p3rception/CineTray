import CoreGraphics

/// Display-crop options for the video player. `.original` keeps the video's
/// native aspect ratio (letterbox-preserving); the others reshape the window
/// to the target ratio and fill-crop the video around its centre.
enum VideoCrop: String, CaseIterable, Identifiable {
    case original
    case ratio4x3
    case ratio16x9
    case ratio21x9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original:  "Original"
        case .ratio4x3:  "4:3"
        case .ratio16x9: "16:9"
        case .ratio21x9: "21:9"
        }
    }

    /// Target width/height ratio, or nil for the video's native ratio.
    var ratio: CGFloat? {
        switch self {
        case .original:  nil
        case .ratio4x3:  4.0 / 3.0
        case .ratio16x9: 16.0 / 9.0
        case .ratio21x9: 21.0 / 9.0
        }
    }
}
