import Foundation

/// Basic now-playing media information and audio volume.
public struct MediaState: Sendable, Equatable {
    /// Artist name of the currently playing track. Nil if the vehicle did not report this field.
    public var nowPlayingArtist: String?
    /// Title of the currently playing track. Nil if the vehicle did not report this field.
    public var nowPlayingTitle: String?
    /// Current audio volume on the vehicle's raw scale. Nil if the vehicle did not report this field.
    public var audioVolume: Double?
    /// Maximum audio volume on the vehicle's raw scale. Nil if the vehicle did not report this field.
    public var audioVolumeMax: Double?
    /// Whether remote media control is currently permitted. Nil if the vehicle did not report this field.
    public var remoteControlEnabled: Bool?

    public init(
        nowPlayingArtist: String? = nil,
        nowPlayingTitle: String? = nil,
        audioVolume: Double? = nil,
        audioVolumeMax: Double? = nil,
        remoteControlEnabled: Bool? = nil,
    ) {
        self.nowPlayingArtist = nowPlayingArtist
        self.nowPlayingTitle = nowPlayingTitle
        self.audioVolume = audioVolume
        self.audioVolumeMax = audioVolumeMax
        self.remoteControlEnabled = remoteControlEnabled
    }
}
