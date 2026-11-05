import SwiftUI

/// Shared search-and-actions layout; the caller owns library state and operations.
struct GalleryMediaToolbar<Actions: View>: View {
    @Binding var query: String
    let placeholder: String
    var isSearching = false
    var showsBackButton = true
    var searchMaxWidth: CGFloat? = nil
    let back: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            if showsBackButton {
                GalleryHoverIcon(symbol: "chevron.left", title: "Albums", identifier: "svt-gallery-back-to-albums", action: back)
            }
            GalleryDesignSearchField(query: $query, placeholder: placeholder, isSearching: isSearching)
                .frame(minWidth: 160, maxWidth: searchMaxWidth ?? .infinity)
            HStack(spacing: 12) { actions }.fixedSize(horizontal: true, vertical: false)
        }
    }
}
