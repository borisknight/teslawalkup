import Foundation

/// Builds `CarServer_Action` bodies for `Command.Media` cases — playback,
/// tracks, favorites, and volume. Infotainment domain.
enum MediaEncoder {
    enum Error: Swift.Error, Equatable {
        /// Protobuf serialization failed.
        case encodingFailed(String)
        /// A command parameter was outside its accepted range (e.g. volume).
        case invalidParameter(String)
    }

    static func encode(_ command: Command.Media) throws -> Data {
        var vehicleAction = CarServer_VehicleAction()

        switch command {
        case .togglePlayback:
            vehicleAction.vehicleActionMsg = .mediaPlayAction(CarServer_MediaPlayAction())

        case .nextTrack:
            vehicleAction.vehicleActionMsg = .mediaNextTrack(CarServer_MediaNextTrack())

        case .previousTrack:
            vehicleAction.vehicleActionMsg = .mediaPreviousTrack(CarServer_MediaPreviousTrack())

        case let .setVolume(volume):
            guard volume.isFinite, volume >= 0, volume <= 11 else {
                throw Error.invalidParameter("volume out of range: \(volume)")
            }
            var sub = CarServer_MediaUpdateVolume()
            sub.volumeAbsoluteFloat = volume
            vehicleAction.vehicleActionMsg = .mediaUpdateVolume(sub)

        case .volumeUp:
            var sub = CarServer_MediaUpdateVolume()
            sub.mediaVolume = .volumeDelta(1)
            vehicleAction.vehicleActionMsg = .mediaUpdateVolume(sub)

        case .volumeDown:
            var sub = CarServer_MediaUpdateVolume()
            sub.mediaVolume = .volumeDelta(-1)
            vehicleAction.vehicleActionMsg = .mediaUpdateVolume(sub)

        case .nextFavorite:
            vehicleAction.vehicleActionMsg = .mediaNextFavorite(CarServer_MediaNextFavorite())

        case .previousFavorite:
            vehicleAction.vehicleActionMsg = .mediaPreviousFavorite(CarServer_MediaPreviousFavorite())
        }

        var action = CarServer_Action()
        action.vehicleAction = vehicleAction

        do {
            return try action.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}
