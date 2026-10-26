import AVFoundation
import CoreLocation
import MyGuideCore
import SwiftData
import SwiftUI

enum AppConstants {
    static let keychainService = "io.github.birgerlie.MyGuide"
    static let apiKeyAccount = "openai-api-key"
}

@Model
final class SelfCheckProbe {
    var createdAt: Date

    init(createdAt: Date = .now) {
        self.createdAt = createdAt
    }
}

struct CheckResult: Equatable {
    var passed: Bool
    var detail: String
}

/// One-shot location + heading probe for the device check.
@MainActor
final class LocationProbe: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var fixContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func run() async -> CheckResult {
        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                authContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return CheckResult(passed: false, detail: "Location permission not granted")
        }
        guard CLLocationManager.headingAvailable() else {
            return CheckResult(passed: false, detail: "Heading (compass) not available")
        }
        let fix: CLLocation? = await withCheckedContinuation { continuation in
            fixContinuation = continuation
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finishFix(nil)
            }
        }
        guard let fix else {
            return CheckResult(passed: false, detail: "No location fix within 15 s")
        }
        return CheckResult(passed: true, detail: "Fix ±\(Int(fix.horizontalAccuracy)) m, heading available")
    }

    private func finishFix(_ location: CLLocation?) {
        fixContinuation?.resume(returning: location)
        fixContinuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            self.authContinuation?.resume(returning: status)
            self.authContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finishFix(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishFix(nil) }
    }
}

@MainActor
@Observable
final class SelfCheckModel {
    var camera: CheckResult?
    var location: CheckResult?
    var keychain: CheckResult?
    var swiftData: CheckResult?
    var running = false

    private var locationProbe: LocationProbe?

    func run() async {
        running = true
        camera = nil; location = nil; keychain = nil; swiftData = nil
        camera = await checkCamera()
        let probe = LocationProbe()
        locationProbe = probe
        location = await probe.run()
        locationProbe = nil
        keychain = checkKeychain()
        swiftData = checkSwiftData()
        running = false
    }

    private func checkCamera() async -> CheckResult {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted
            ? CheckResult(passed: true, detail: "Camera access granted")
            : CheckResult(passed: false, detail: "Camera permission not granted")
    }

    private func checkKeychain() -> CheckResult {
        let store = KeychainStore(service: AppConstants.keychainService)
        do {
            try store.write("probe", account: "selfcheck")
            let value = try store.read("selfcheck")
            try store.delete("selfcheck")
            guard value == "probe" else {
                return CheckResult(passed: false, detail: "Read back \(value ?? "nil"), expected probe")
            }
            return CheckResult(passed: true, detail: "Write, read and delete succeeded")
        } catch {
            return CheckResult(passed: false, detail: "Keychain error: \(error)")
        }
    }

    private func checkSwiftData() -> CheckResult {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let configuration = ModelConfiguration(url: support.appending(path: "selfcheck.store"))
            let container = try ModelContainer(for: SelfCheckProbe.self, configurations: configuration)
            let context = ModelContext(container)
            context.insert(SelfCheckProbe())
            try context.save()
            let probes = try context.fetch(FetchDescriptor<SelfCheckProbe>())
            guard probes.count >= 1 else {
                return CheckResult(passed: false, detail: "Saved probe not found on fetch")
            }
            let count = probes.count
            probes.forEach { context.delete($0) }
            try context.save()
            return CheckResult(passed: true, detail: "Saved and fetched \(count) probe(s), then deleted")
        } catch {
            return CheckResult(passed: false, detail: "SwiftData error: \(error)")
        }
    }
}

struct SelfCheckView: View {
    @State private var model = SelfCheckModel()

    var body: some View {
        NavigationStack {
            List {
                row("Camera", model.camera)
                row("Location", model.location)
                row("Keychain", model.keychain)
                row("SwiftData", model.swiftData)
            }
            .navigationTitle("Device check")
            .toolbar {
                Button("Run checks") { Task { await model.run() } }
                    .disabled(model.running)
            }
            .task { await model.run() }
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ result: CheckResult?) -> some View {
        HStack(alignment: .top) {
            Text(result == nil ? "…" : (result!.passed ? "✓" : "✗"))
                .foregroundStyle(result?.passed == true ? .green : (result == nil ? .secondary : .red))
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(result?.detail ?? "Waiting").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
