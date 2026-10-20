import SwiftUI

/// 「ふわふわパピー・トーク」カラーテーマ＆デザインシステム
public enum AppTheme {
    // MARK: - パレット定義
    public static let puppyPink = Color(hex: "#FB7185")       // 華やかでやさしいメインピンク
    public static let puppyDeepPink = Color(hex: "#E11D48")   // 引き締めアクセントローズ
    public static let puppySoftPink = Color(hex: "#FBCFE8")   // パステルサクラピンク
    public static let puppyPalePink = Color(hex: "#FDF2F8")   // 背景用ペールピンク
    
    public static let puppyPeach = Color(hex: "#FED7AA")      // 温かいパステルピーチ
    public static let puppyPalePeach = Color(hex: "#FFF7ED")  // 最明部ピーチ
    
    public static let puppyLavender = Color(hex: "#C084FC")   // 透明感のあるラベンダー
    public static let puppySoftLavender = Color(hex: "#EDE9FE") // ペールラベンダー
    
    public static let textPrimary = Color(hex: "#1F2937")     // 読みやすいソフトダーク
    public static let textSecondary = Color(hex: "#6B7280")   // 控えめなグレー
    
    // MARK: - グラデーション
    /// 3D空間の背景グラデーション（ピーチラベンダーサクラ）
    public static let backgroundGradient = LinearGradient(
        colors: [
            Color(hex: "#FFF1EB"), // 柔らかなピーチ
            Color(hex: "#FDEBF3"), // 優しいサクラピンク
            Color(hex: "#EDE9FE")  // ほんのりラベンダー
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    /// ユーザー吹き出しのグラデーション
    public static let userBubbleGradient = LinearGradient(
        colors: [
            Color(hex: "#FB7185"),
            Color(hex: "#F43F5E")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    /// プライマリボタンのグラデーション（送信・決定）
    public static let primaryButtonGradient = LinearGradient(
        colors: [
            Color(hex: "#FB7185"),
            Color(hex: "#EC4899")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    /// 16進数カラーコード（例: "#FB7185"）からColorを生成
    public init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted))
        var int: UInt64 = 0
        scanner.scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
