import SwiftUI
import AVFoundation

@main
struct GlassesMicApp: App {
    var body: some Scene { WindowGroup { MicView() } }
}

struct MicView: View {
    @StateObject private var mic = MicController()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            Form {
                Section("Шаг 1 — подключение") {
                    Text("Подключи очки к iPhone по Bluetooth. Проверка работает, пока приложение открыто на телефоне.")
                    Button("Разрешить микрофон и найти устройства") { mic.prepare() }
                        .frame(minHeight: 44).disabled(mic.recording || mic.preparing)
                    Picker("Bluetooth-микрофон", selection: $mic.selectedUID) {
                        Text("Выбери очки").tag("")
                        ForEach(mic.inputs, id: \.uid) { input in
                            Text(input.portName).tag(input.uid)
                        }
                    }.disabled(mic.recording || mic.preparing)
                }
                Section("Состояние") {
                    Text(mic.status).textSelection(.enabled)
                    Text("Фактический вход: \(mic.route)")
                    Text("Запись: \(Int(mic.seconds)) / 120 секунд")
                    ProgressView(value: mic.level)
                        .accessibilityLabel("Уровень микрофона")
                }
                Section("Шаг 2 — запись") {
                    Button("Начать запись") { mic.start() }
                        .frame(minHeight: 44)
                        .disabled(mic.recording || mic.preparing || mic.selectedUID.isEmpty)
                    Button("Стоп") { mic.stop() }
                        .frame(minHeight: 44).disabled(!mic.recording)
                    Button("Прослушать запись") { mic.play() }
                        .frame(minHeight: 44).disabled(mic.recording || mic.clip == nil)
                    Button("Остановить прослушивание") { mic.stopPlayback() }
                        .frame(minHeight: 44)
                    if let clip = mic.clip {
                        ShareLink("Сохранить или поделиться записью", item: clip)
                            .frame(minHeight: 44)
                    }
                    Button("Удалить запись", role: .destructive) { mic.discard() }
                        .frame(minHeight: 44).disabled(mic.recording || mic.clip == nil)
                }
                Section("Что проверяем") {
                    Text("В списке доступны только Bluetooth HFP-микрофоны. Выбери именно свои очки. Если iOS переключится на другой вход, запись остановится.")
                    Text("Запись хранится локально. Подключение Telegram и управление записью с экрана очков пока не добавлены.")
                }
            }
            .navigationTitle("Микрофон очков")
            .onChange(of: phase) { _, next in
                if next != .active { mic.suspend() }
            }
        }
    }
}

@MainActor
final class MicController: ObservableObject {
    @Published var inputs: [AVAudioSessionPortDescription] = []
    @Published var selectedUID = ""
    @Published var status = "Разреши доступ к микрофону для поиска очков."
    @Published var route = "не подключён"
    @Published var recording = false
    @Published var preparing = false
    @Published var seconds = 0.0
    @Published var level: Float = 0
    @Published var clip: URL?

    private let session = AVAudioSession.sharedInstance()
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var activeUID = ""
    private var operation: Task<Void, Never>?

    func prepare() {
        guard !preparing, !recording else { return }
        preparing = true
        operation = Task {
            let allowed = await AVAudioApplication.requestRecordPermission()
            defer { preparing = false }
            guard !Task.isCancelled else { return }
            guard allowed else {
                status = "Разреши микрофон в настройках iPhone для приложения «Микрофон очков»."
                return
            }
            do {
                stopPlayback()
                // HFP is the system Bluetooth input route; no private Meta APIs.
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
                try session.setActive(true)
                try await Task.sleep(nanoseconds: 700_000_000)
                inputs = (session.availableInputs ?? []).filter { $0.portType == .bluetoothHFP }
                if !inputs.contains(where: { $0.uid == selectedUID }) { selectedUID = "" }
                updateRoute()
                status = inputs.isEmpty
                    ? "Bluetooth-микрофон не обнаружен. Проверь подключение очков и повтори поиск."
                    : "Выбери очки в списке. Затем нажми «Начать запись»."
            } catch { fail(error) }
        }
    }

    func start() {
        guard !recording, !preparing else { return }
        preparing = true
        operation = Task {
            defer { preparing = false }
            do {
                stopPlayback()
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
                try session.setActive(true)
                guard let port = session.availableInputs?.first(where: {
                    $0.uid == selectedUID && $0.portType == .bluetoothHFP
                }) else { status = "Выбранный микрофон отключён. Повтори поиск."; return }
                try session.setPreferredInput(port)
                try await Task.sleep(nanoseconds: 700_000_000)
                updateRoute()
                guard isSelectedInput else {
                    status = "iOS не выбрала микрофон очков. Запись не начата."
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("glasses-\(UUID().uuidString).m4a")
                let next = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32000
                ])
                next.isMeteringEnabled = true
                guard next.prepareToRecord(), next.record() else {
                    try? FileManager.default.removeItem(at: url)
                    status = "Не удалось начать запись."; return
                }
                if let old = clip { try? FileManager.default.removeItem(at: old) }
                clip = nil
                recorder = next
                activeUID = selectedUID
                seconds = 0
                recording = true
                status = "Записываю с выбранного Bluetooth-микрофона."
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch { fail(error) }
        }
    }

    private var isSelectedInput: Bool {
        session.currentRoute.inputs.contains { $0.uid == selectedUID && $0.portType == .bluetoothHFP }
    }

    private func tick() {
        guard recording, let recorder else { return }
        updateRoute()
        guard session.currentRoute.inputs.contains(where: {
            $0.uid == activeUID && $0.portType == .bluetoothHFP
        }) else {
            stop()
            status = "Вход изменился: запись остановлена. Конец записи мог попасть с другого микрофона; проверь её."
            return
        }
        guard recorder.isRecording else {
            stop(); status = "Запись прервана системой. Проверь сохранённый фрагмент."; return
        }
        recorder.updateMeters()
        seconds = recorder.currentTime
        level = min(1, max(0, pow(10, recorder.averagePower(forChannel: 0) / 20)))
        if seconds >= 120 { stop() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        guard let recorder else { return }
        seconds = max(seconds, recorder.currentTime)
        recorder.stop()
        clip = recorder.url
        self.recorder = nil
        recording = false
        level = 0
        status = "Запись сохранена. Прослушай её и проверь источник звука."
        deactivate()
    }

    func play() {
        guard !recording, let clip else { return }
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            player = try AVAudioPlayer(contentsOf: clip)
            guard player?.play() == true else { status = "Не удалось воспроизвести запись."; return }
            status = "Прослушивание. Выход: " + session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        } catch { fail(error) }
    }

    func stopPlayback() { player?.stop(); player = nil; deactivate() }
    func discard() {
        guard !recording else { return }
        stopPlayback()
        if let clip { try? FileManager.default.removeItem(at: clip) }
        clip = nil; seconds = 0; status = "Запись удалена."
    }
    func suspend() {
        operation?.cancel()
        if recording { stop() }
        stopPlayback()
    }
    private func updateRoute() {
        route = session.currentRoute.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        if route.isEmpty { route = "нет входа" }
    }
    private func deactivate() { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
    private func fail(_ error: Error) { status = "Ошибка: \(error.localizedDescription)"; deactivate() }
}
