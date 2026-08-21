//
//  LocalWeatherProvider.swift
//  Qoob
//
//  The WeatherKit + CoreLocation edge for live weather (Settings › "Match
//  local weather"). Named to avoid colliding with WeatherKit's own
//  `WeatherService` type. Every failure here — permission denied, no
//  network, a missing entitlement, the simulator — degrades silently to "no
//  snapshot": `SkySystem` already treats that as "no weather", not "no
//  game". See `SkyModel.swift`/`SkySystem.swift` for the pure-model side
//  this feeds.
//
//  tvOS has no practical CoreLocation "when in use" prompt flow, so it gets a
//  stub with the identical public surface — mirroring `Haptics.swift`'s
//  platform split — rather than `GameController` growing an `#if os(tvOS)`
//  of its own.
//

#if !os(tvOS)
import CoreLocation
import WeatherKit
#endif
import Foundation

/// Live status, surfaced to Settings so the footnote can explain itself when
/// there's nothing to show.
enum WeatherStatus: String {
    case off, requesting, denied, unavailable, live
}

#if !os(tvOS)

@MainActor
final class LocalWeatherProvider: NSObject, CLLocationManagerDelegate {
    /// What `sky.ingest(_:)` actually sees. Prefers `debugOverride` when one is
    /// set, so a fixed test scenario can't be silently clobbered by a real
    /// fetch completing in the background.
    var snapshot: SkySnapshot? {
        #if DEBUG
        if let debugOverride { return debugOverride }
        #endif
        return fetchedSnapshot
    }
    private var fetchedSnapshot: SkySnapshot?

    #if DEBUG
    /// Testing hook: when set, `snapshot` returns this instead of whatever was
    /// actually fetched, and `refreshIfNeeded` does no location/network work at
    /// all. This is what makes golden hour, precipitation and storms fully
    /// developable and verifiable on the simulator with no WeatherKit
    /// provisioning — see BUILD.md.
    var debugOverride: SkySnapshot? {
        didSet { if debugOverride != nil { status = .live } }
    }
    #endif

    private(set) var status: WeatherStatus = .off {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    /// Set by `GameController` to mirror `status` into `GameViewModel` for the
    /// Settings footnote.
    var onStatusChange: ((WeatherStatus) -> Void)?

    private let manager = CLLocationManager()
    private var isFetching = false
    private var hasLoggedFailure = false
    private var lastLocation: CLLocation?
    private var lastLocationAt: Date?

    override init() {
        super.init()
        // City-block resolution is all weather needs — this is also what keeps
        // the permission prompt itself from asking for anything more precise.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        manager.delegate = self
    }

    /// Called from `GameController.init` when the setting was already on from a
    /// previous session. Never prompts — only resumes if permission is already
    /// granted, so a returning player doesn't see a prompt at launch.
    func startIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            status = .requesting
            manager.requestLocation()
        default:
            break
        }
    }

    /// Called only when the player switches the setting on in Settings — the
    /// one call site allowed to show a permission prompt.
    func start() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            status = .requesting
            manager.requestLocation()
        case .notDetermined:
            status = .requesting
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .unavailable
        }
    }

    func stop() {
        fetchedSnapshot = nil
        status = .off
        lastLocation = nil
        lastLocationAt = nil
    }

    /// Polled once a frame by `GameController.updateSky()` — harmless to call
    /// constantly, since it only actually does anything once every
    /// `VisualTuning.sky.refreshInterval`.
    func refreshIfNeeded(now: Date) {
        #if DEBUG
        guard debugOverride == nil else { return }
        #endif
        guard status != .off, !isFetching else { return }
        let stale = snapshot.map { now.timeIntervalSince($0.fetchedAt) > VisualTuning.sky.refreshInterval } ?? true
        if stale {
            if let location = lastLocation, let at = lastLocationAt, now.timeIntervalSince(at) < 2 * 3600 {
                Task { await fetch(at: location) }
            } else if manager.authorizationStatus == .authorizedWhenInUse
                        || manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
        // A snapshot that's gone very stale (repeated fetch failures) is worse
        // than none at all — a room dressed for a storm that passed hours ago.
        if let existing = fetchedSnapshot, now.timeIntervalSince(existing.fetchedAt) > VisualTuning.sky.refreshInterval * 6 {
            fetchedSnapshot = nil
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard status != .off else { return }
            manager.requestLocation()
        case .denied, .restricted:
            status = .denied
        case .notDetermined:
            break
        @unknown default:
            status = .unavailable
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        lastLocationAt = Date()
        Task { await fetch(at: location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        markUnavailable()
    }

    // MARK: - Fetch

    private func fetch(at location: CLLocation) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let (current, daily) = try await WeatherKit.WeatherService.shared
                .weather(for: location, including: .current, .daily)
            let today = daily.first
            fetchedSnapshot = SkySnapshot(
                condition: SkyCondition(current.condition),
                sun: SolarWindow(sunrise: today?.sun.sunrise, sunset: today?.sun.sunset,
                                 validFor: today?.date ?? Date()),
                fetchedAt: Date())
            status = .live
            hasLoggedFailure = false
        } catch {
            markUnavailable()
        }
    }

    private func markUnavailable() {
        status = .unavailable
        guard !hasLoggedFailure else { return }
        hasLoggedFailure = true
        #if DEBUG
        print("LocalWeatherProvider: weather fetch failed, falling back to the default sky")
        #endif
    }
}

private extension SkyCondition {
    /// Everything WeatherKit reports collapses into one of five moods. The
    /// `default` case is mandatory, not defensive: `WeatherCondition` is a
    /// framework enum Apple adds cases to over time, and an exhaustive switch
    /// here would break on the next SDK instead of just under-classifying.
    init(_ condition: WeatherCondition) {
        switch condition {
        case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms,
             .strongStorms, .tropicalStorm, .hurricane:
            self = .thunderstorm
        case .drizzle, .heavyRain, .rain, .sunShowers, .hail, .freezingRain, .freezingDrizzle:
            self = .rain
        case .flurries, .sleet, .snow, .sunFlurries, .wintryMix, .blizzard, .blowingSnow, .heavySnow:
            self = .snow
        case .cloudy, .mostlyCloudy, .partlyCloudy, .foggy, .haze, .smoky, .blowingDust, .breezy, .windy:
            self = .cloudy
        default:
            self = .clear
        }
    }
}

#else

/// tvOS stub: CoreLocation's "when in use" prompt flow doesn't apply there, so
/// the feature simply never turns on — the same public surface as the real
/// provider, so `GameController` needs no platform check of its own.
@MainActor
final class LocalWeatherProvider {
    private(set) var snapshot: SkySnapshot?
    private(set) var status: WeatherStatus = .unavailable
    var onStatusChange: ((WeatherStatus) -> Void)?

    func startIfAuthorized() {}
    func start() { status = .unavailable; onStatusChange?(status) }
    func stop() { status = .off }
    func refreshIfNeeded(now: Date) {}
}

#endif
