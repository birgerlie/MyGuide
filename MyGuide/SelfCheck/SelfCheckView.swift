import AVFoundation
import CoreLocation
import MyGuideCore
import SwiftData
import SwiftUI

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

private enum FixFailure: Error {
    case timeout
}

/// One-shot location + heading probe for the device check.
@MainActor
final class LocationProbe: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus?, Never>?
    private var authTimeout: Task<Void, Never>?
    private var fixContinuation: CheckedContinuation<Result<CLLocation, Error>, Never>?
    private var fixTimeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func run(language: StoryLanguage) async -> CheckResult {
        var status: CLAuthorizationStatus? = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                authContinuation = continuation
                authTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.finishAuth(nil)
                }
                manager.requestWhenInUseAuthorization()
            }
        }
        guard let status else {
            return CheckResult(passed: false, detail: SelfCheckTexts.noPermissionAnswer(language))
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return CheckResult(passed: false, detail: SelfCheckTexts.locationNotGranted(language))
        }
        guard CLLocationManager.headingAvailable() else {
            return CheckResult(passed: false, detail: SelfCheckTexts.noHeading(language))
        }
        let outcome: Result<CLLocation, Error> = await withCheckedContinuation { continuation in
            fixContinuation = continuation
            fixTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.finishFix(.failure(FixFailure.timeout))
            }
            manager.requestLocation()
        }
        switch outcome {
        case .success(let fix):
            return CheckResult(passed: true, detail: SelfCheckTexts.fix(accuracyM: Int(fix.horizontalAccuracy), language))
        case .failure(let error):
            return CheckResult(passed: false, detail: Self.describe(error, language))
        }
    }

    private static func describe(_ error: Error, _ language: StoryLanguage) -> String {
        if error is FixFailure { return SelfCheckTexts.noFix(language) }
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain, nsError.code == CLError.denied.rawValue {
            return SelfCheckTexts.locationDenied(language)
        }
        return SelfCheckTexts.locationError(domain: nsError.domain, code: nsError.code,
                                            description: nsError.localizedDescription, language)
    }

    private func finishAuth(_ status: CLAuthorizationStatus?) {
        authTimeout?.cancel()
        authTimeout = nil
        authContinuation?.resume(returning: status)
        authContinuation = nil
    }

    private func finishFix(_ outcome: Result<CLLocation, Error>) {
        fixTimeout?.cancel()
        fixTimeout = nil
        fixContinuation?.resume(returning: outcome)
        fixContinuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            self.finishAuth(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.finishFix(.success(last)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishFix(.failure(error)) }
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
        guard !running else { return }
        running = true
        // The results are worded in the story language as it is when the run starts.
        let language = AppServices.currentStoryLanguage()
        camera = nil; location = nil; keychain = nil; swiftData = nil
        // Local checks first so they always run, even if a permission prompt never resolves.
        keychain = checkKeychain(language)
        swiftData = checkSwiftData(language)
        camera = await checkCamera(language)
        let probe = LocationProbe()
        locationProbe = probe
        location = await probe.run(language: language)
        locationProbe = nil
        running = false
    }

    private func checkCamera(_ language: StoryLanguage) async -> CheckResult {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted
            ? CheckResult(passed: true, detail: SelfCheckTexts.cameraGranted(language))
            : CheckResult(passed: false, detail: SelfCheckTexts.cameraNotGranted(language))
    }

    private func checkKeychain(_ language: StoryLanguage) -> CheckResult {
        let store = KeychainStore(service: AppServices.keychainService)
        do {
            try store.write("probe", account: "selfcheck")
            let value = try store.read("selfcheck")
            try store.delete("selfcheck")
            guard value == "probe" else {
                return CheckResult(passed: false, detail: SelfCheckTexts.keychainMismatch(value ?? "nil", language))
            }
            return CheckResult(passed: true, detail: SelfCheckTexts.keychainPassed(language))
        } catch {
            return CheckResult(passed: false, detail: SelfCheckTexts.keychainError(error, language))
        }
    }

    private func checkSwiftData(_ language: StoryLanguage) -> CheckResult {
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
                return CheckResult(passed: false, detail: SelfCheckTexts.probeNotFound(language))
            }
            let count = probes.count
            probes.forEach { context.delete($0) }
            try context.save()
            return CheckResult(passed: true, detail: SelfCheckTexts.swiftDataPassed(count: count, language))
        } catch {
            return CheckResult(passed: false, detail: SelfCheckTexts.swiftDataError(error, language))
        }
    }
}

struct SelfCheckView: View {
    @State private var model = SelfCheckModel()
    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english

    var body: some View {
        // Pushed from Settings, so it lives in the app's NavigationStack rather than its own.
        List {
            Section {
                row(SelfCheckTexts.camera(storyLanguage), model.camera)
                row(SelfCheckTexts.location(storyLanguage), model.location)
                row(SelfCheckTexts.keychain(storyLanguage), model.keychain)
                row(SelfCheckTexts.swiftData(storyLanguage), model.swiftData)
            }
            .themedRows()
        }
        .themedList()
        .themedTitle(SelfCheckTexts.title(storyLanguage))
        .toolbar {
            Button(SelfCheckTexts.runChecks(storyLanguage)) { Task { await model.run() } }
                .disabled(model.running)
        }
        .task { await model.run() }
    }

    @ViewBuilder
    private func row(_ title: String, _ result: CheckResult?) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.unit) {
            CheckMark(passed: result?.passed, passedText: SelfCheckTexts.passed(storyLanguage),
                      failedText: SelfCheckTexts.failed(storyLanguage), waitingText: SelfCheckTexts.waiting(storyLanguage))
            VStack(alignment: .leading, spacing: Theme.Spacing.unit / 4) {
                Text(title).font(Theme.Font.bodyMedium)
                Text(result?.detail ?? SelfCheckTexts.waiting(storyLanguage))
                    .font(Theme.Font.caption)
                    .opacity(0.75)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
