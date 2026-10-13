import SwiftUI

enum SessionColor {
    static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint]
    static func color(for index: Int) -> Color { palette[((index % palette.count) + palette.count) % palette.count] }
}
