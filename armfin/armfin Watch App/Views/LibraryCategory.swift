/// The four Library browse tabs — Artists, Albums, Songs, Genres. A
/// top-level type (not nested in `RootView`) so it can be shared by
/// `RootView` and each of the four browse screens without those screens
/// importing a `RootView`-owned type.
enum LibraryCategory: String, CaseIterable {
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case genres = "Genres"
}
