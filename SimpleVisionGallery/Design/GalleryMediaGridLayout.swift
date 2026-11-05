import SwiftUI

/// New libraries start with generous photos; saved thumbnail-size choices remain in force.
enum GalleryMediaGridLayout {
    static let defaultThumbnailSize = 240.0
    static let gap: CGFloat = 8
    static func columns(thumbnailSize: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize * 1.08),
            spacing: gap, alignment: .top)]
    }
}
