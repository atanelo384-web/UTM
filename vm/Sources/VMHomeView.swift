//
// VM — start screen: Android name and version, iPhone specifications, Start and settings.
//

import SwiftUI

struct VMHomeView: View {
    @EnvironmentObject private var data: UTMData
    @ObservedObject private var settings = VMShellSettings.shared
    @ObservedObject private var jit = VMJIT.shared
    @ObservedObject private var shell = VMShell.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isSettingsShown = false
    @State private var isJITHelpShown = false
    @State private var isStartPendingJIT = false
    @State private var storage = VMDevice.storage()

    private var vm: VMData? { shell.androidVM(in: data) }
    private var config: UTMQemuConfiguration? { vm?.config as? UTMQemuConfiguration }
    private var pending: UTMPendingVirtualMachine? { data.pendingVMs.first }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    androidCard
                    deviceCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            startArea
            settingsButton
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .alert(item: $shell.message) { m in
            Alert(title: Text(m.title), message: Text(m.text), dismissButton: .default(Text("OK")))
        }
        .overlay(BusyOverlay())
        .sheet(isPresented: $isSettingsShown, onDismiss: refreshStorage) {
            VMSettingsScreen().environmentObject(data)
        }
        .sheet(isPresented: $isJITHelpShown) {
            VMJITHelpView()
        }
        .onAppear {
            settings.applyAppDefaults()
            jit.refresh()
            refreshStorage()
            data.triggeriOSNetworkAccessPrompt()
            Task {
                await data.listRefresh()
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            refreshStorage()
            jit.refresh()
            if isStartPendingJIT {
                Task {
                    let ok = await jit.waitForAttach()
                    isStartPendingJIT = false
                    if ok {
                        start()
                    } else {
                        shell.message = VMShellMessage(title: "JIT не включился", text: "StikDebug не подключился к VM. Проверьте, что включён LocalDevVPN и в StikDebug загружен файл сопряжения, затем нажмите «Старт» ещё раз.")
                    }
                }
            }
        }
        .onChange(of: data.pendingVMs.count) { count in
            if count == 0 {
                UIApplication.shared.isIdleTimerDisabled = false
                refreshStorage()
            }
        }
    }

    // MARK: - Android

    @ViewBuilder
    private var androidCard: some View {
        let info = VMAndroidInfo(config: config)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.green.opacity(0.18))
                    Image(systemName: "smartphone")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.green)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    if vm != nil {
                        Text(info.android)
                            .font(.system(size: 28, weight: .bold))
                        Text(info.title)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Android 16")
                            .font(.system(size: 28, weight: .bold))
                        Text("LineageOS 23.2 · не загружен")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if vm != nil {
                Divider()
                VMInfoRow(title: "Память", value: vmFormatMiB(settings.memoryMiB))
                VMInfoRow(title: "Ядра", value: "\(settings.cpuCount)")
                VMInfoRow(title: "Экран", value: settings.resolution.title)
                VMInfoRow(title: "JIT", value: jit.isEnabled ? "включён" : "включится при старте", valueColor: jit.isEnabled ? .green : .secondary)
            } else if let pending = pending {
                VMDownloadProgressView(pending: pending)
            } else {
                Divider()
                Text("Образ Android скачается из интернета один раз: \(vmFormatBytes(VMAndroidImage.downloadSize)), после распаковки займёт около \(vmFormatBytes(VMAndroidImage.unpackedSize)). Пока идёт загрузка, не закрывайте приложение.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !shell.hasSpaceForDownload {
                    Text("Мало свободного места: нужно хотя бы \(vmFormatBytes(VMAndroidImage.downloadSize + VMAndroidImage.unpackedSize + 500_000_000)).")
                        .font(.footnote)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .vmCard()
    }

    // MARK: - iPhone

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Этот iPhone")
                .font(.headline)
            VMInfoRow(title: "Модель", value: VMDevice.modelName)
            VMInfoRow(title: "Процессор", value: VMDevice.chipName)
            VMInfoRow(title: "Ядра", value: coresText)
            VMInfoRow(title: "Оперативная память", value: VMDevice.ramDescription)
            VMInfoRow(title: "Система", value: VMDevice.iosVersion)
            VMInfoRow(title: "Свободно", value: "\(vmFormatBytes(storage.free)) из \(vmFormatBytes(storage.total))")
        }
        .vmCard()
    }

    private var coresText: String {
        let c = VMDevice.cpuCores
        if c.performance > 0 && c.efficiency > 0 {
            return "\(c.total) (\(c.performance) + \(c.efficiency))"
        }
        return "\(c.total)"
    }

    // MARK: - Start

    @ViewBuilder
    private var startArea: some View {
        VStack(spacing: 8) {
            if vm != nil {
                Button(action: startPressed) {
                    HStack(spacing: 10) {
                        if shell.isPreparing || isStartPendingJIT {
                            ProgressView().progressViewStyle(.circular).tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(isStartPendingJIT ? "Включаю JIT…" : "Старт")
                    }
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundColor(.white)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(shell.isPreparing || isStartPendingJIT)
            } else if pending == nil {
                Button {
                    shell.download(into: data)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Скачать Android")
                    }
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundColor(.white)
                    .background(shell.hasSpaceForDownload ? Color.accentColor : Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(!shell.hasSpaceForDownload)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private var settingsButton: some View {
        Button {
            isSettingsShown = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
                .frame(width: 56, height: 48)
        }
        .accessibilityLabel("Настройки")
        .padding(.vertical, 6)
    }

    private func startPressed() {
        jit.refresh()
        guard jit.isEnabled else {
            isStartPendingJIT = true
            jit.requestFromStikDebug { opened in
                if !opened {
                    isStartPendingJIT = false
                    isJITHelpShown = true
                }
            }
            return
        }
        start()
    }

    private func start() {
        guard let vm = vm else { return }
        shell.start(vm: vm, data: data, settings: settings)
    }

    private func refreshStorage() {
        storage = VMDevice.storage()
    }
}

// MARK: - Pieces

struct VMInfoRow: View {
    let title: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

struct VMDownloadProgressView: View {
    @ObservedObject var pending: UTMPendingVirtualMachine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if pending.downloadProgress >= 1 {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Распаковка образа…")
                        .font(.subheadline)
                }
            } else {
                ProgressView(value: Double(pending.downloadProgress))
                HStack {
                    Text("Загрузка \(Int(pending.downloadProgress * 100))%")
                    Spacer()
                    if let speed = pending.estimatedDownloadSpeed {
                        Text(speed)
                    }
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                if let eta = pending.estimatedTimeRemaining {
                    Text(eta)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            Button("Отменить", role: .destructive) {
                pending.cancel()
            }
            .font(.footnote)
        }
    }
}

struct VMJITHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jit = VMJIT.shared

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Без JIT эмулятор работает слишком медленно, поэтому VM запускает Android только с JIT. На iOS его включает приложение StikDebug.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Один раз") {
                    VMStep(n: 1, text: "Поставьте StikDebug через Sideloadly, так же как VM.")
                    VMStep(n: 2, text: "Поставьте LocalDevVPN из App Store.")
                    VMStep(n: 3, text: "Загрузите в StikDebug файл сопряжения (его делают на ПК, см. инструкцию к VM).")
                }
                Section("Каждый раз") {
                    VMStep(n: 1, text: "Включите LocalDevVPN.")
                    VMStep(n: 2, text: "В VM нажмите «Старт»: VM сама откроет StikDebug, он включит JIT и вернёт вас обратно.")
                }
                Section {
                    HStack {
                        Text("JIT сейчас")
                        Spacer()
                        Text(jit.isEnabled ? "включён" : "выключен")
                            .foregroundColor(jit.isEnabled ? .green : .secondary)
                    }
                    Button("Открыть StikDebug") {
                        jit.requestFromStikDebug { _ in }
                    }
                }
            }
            .navigationTitle("Как включить JIT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

private struct VMStep: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n).")
                .font(.body.monospacedDigit())
                .foregroundColor(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VMCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension View {
    func vmCard() -> some View {
        modifier(VMCardModifier())
    }
}
