import Foundation

/// Extended now-playing media info: album, source, and track timing.
public struct MediaDetailState: Sendable, Equatable {
    /// Total duration of the current track in seconds. Nil if the vehicle did not report this field.
    public var nowPlayingDurationSeconds: Double?
    /// Elapsed playback time of the current track in seconds. Nil if the vehicle did not report this field.
    public var nowPlayingElapsedSeconds: Double?
    /// Album name of the currently playing track. Nil if the vehicle did not report this field.
    public var nowPlayingAlbum: String?
    /// Radio station name, if the current source is a radio. Nil if the vehicle did not report this field.
    public var nowPlayingStation: String?
    /// Human-readable name of the media source (e.g. Spotify, TuneIn). Nil if the vehicle did not report this field.
    public var nowPlayingSource: String?
    /// Name advertised by the connected A2DP Bluetooth source. Nil if the vehicle did not report this field.
    public var a2dpSourceName: String?

    public init(
        nowPlayingDurationSeconds: Double? = nil,
        nowPlayingElapsedSeconds: Double? = nil,
        nowPlayingAlbum: String? = nil,
        nowPlayingStation: String? = nil,
        nowPlayingSource: String? = nil,
        a2dpSourceName: String? = nil,
    ) {
        self.nowPlayingDurationSeconds = nowPlayingDurationSeconds
        self.nowPlayingElapsedSeconds = nowPlayingElapsedSeconds
        self.nowPlayingAlbum = nowPlayingAlbum
        self.nowPlayingStation = nowPlayingStation
        self.nowPlayingSource = nowPlayingSource
        self.a2dpSourceName = a2dpSourceName
    }
}
