import Network
import Observation

/// Probes local network access by browsing for Bonjour HTTP services.
/// Reaching `.ready` or discovering any services confirms the OS has granted
/// local network access; prior to that the status remains `.unknown`.
@MainActor
@Observable
final class LocalNetworkAccessMonitor {
    enum Status { case unknown, granted }

    private(set) var status: Status = .unknown
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        browser = b

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, case .ready = state else { return }
                self.status = .granted
            }
        }

        b.browseResultsChangedHandler = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.status = .granted
            }
        }

        b.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
