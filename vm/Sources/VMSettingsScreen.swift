//
// VM — settings: emulator parameters and the specifications of the iPhone.
//

import SwiftUI

struct VMSettingsScreen: View {
    @EnvironmentObject private var data: UTMData
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = VMShellSettings.shared
    @ObservedObject private var jit = VMJIT.shared
    @ObservedObject private var shell = VMShell.shared

    @State private var storage = VMDevice.storage()
    @State private var appMemoryNow = VMDevice.appMemoryAvailable
    @State private var androidSize: Int64 = 0
    @State private var isDeleteConfirmShown = false
    @State private var isResetConfirmShown = false
    @State private var isJITHelpShown = false

    private var vm: VMData? { shell.androidVM(in: data) }

    var body: some View {
        NavigationView {
            Form {
                emulatorSection
                androidSection
                specsSection
                maintenanceSection
                Section {
                    EmptyView()
                } footer: {
                    Text("VM основана на открытом эмуляторе UTM (QEMU) и LineageOS для виртуальных машин. Android здесь эмулируется программно, поэтому работает медленнее, чем на настоящем телефоне.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $isJITHelpShown) {
                VMJITHelpView()
            }
            .onAppear(perform: refresh)
        }
    }

    // MARK: - Emulator

    private var emulatorSection: some View {
        Section {
            Picker("Оперативная память", selection: $settings.memoryMiB) {
                ForEach(VMShellSettings.memoryChoices, id: \.self) { mib in
                    Text(mib == settings.recommendedMemoryMiB ? "\(vmFormatMiB(mib)) (рекоменд.)" : vmFormatMiB(mib)).tag(mib)
                }
            }
            Picker("Ядра процессора", selection: $settings.cpuCount) {
                ForEach(VMShellSettings.cpuChoices.filter { $0 <= VMDevice.cpuCores.total }, id: \.self) { n in
                    Text("\(n)").tag(n)
                }
            }
            Picker("Кэш JIT", selection: $settings.jitCacheMiB) {
                ForEach(VMShellSettings.jitChoices, id: \.self) { mib in
                    Text(vmFormatMiB(mib)).tag(mib)
                }
            }
            Picker("Разрешение", selection: $settings.resolution) {
                ForEach(VMResolution.allCases) { r in
                    Text(r.title).tag(r)
                }
            }
            Toggle("Ускорение графики (GPU)", isOn: $settings.gpuAcceleration)
            Picker("Частота кадров", selection: $settings.fpsLimit) {
                Text("Без ограничения").tag(0)
                Text("60 кадров/с").tag(60)
                Text("30 кадров/с").tag(30)
            }
            Toggle("Звук", isOn: $settings.sound)
            Toggle("Интернет", isOn: $settings.network)
        } header: {
            Text("Эмулятор")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Расход памяти: около \(vmFormatMiB(settings.estimatedUsageMiB)) из \(vmFormatMiB(settings.appMemoryLimitMiB)), которые iOS даёт приложению.")
                if settings.isOverMemoryLimit {
                    Text("Это больше лимита: iOS может закрыть VM во время работы. Уменьшите память или кэш JIT.")
                        .foregroundColor(.red)
                }
                Text("«\(VMResolution.half.title)» рисует вчетверо меньше пикселей, поэтому Android работает быстрее, но картинка мягче. Ускорение графики переносит отрисовку на GPU iPhone; выключайте его, только если экран Android остаётся чёрным.")
                Text("Изменения применяются при следующем нажатии «Старт».")
            }
        }
    }

    private var androidSection: some View {
        Section {
            Toggle("Режим для слабых устройств", isOn: $settings.lowPerformanceMode)
            Toggle("ZRAM (сжатие памяти)", isOn: $settings.zram)
            Toggle("Анимация загрузки", isOn: $settings.bootAnimation)
        } header: {
            Text("Android")
        } footer: {
            Text("Режим для слабых устройств и ZRAM помогают Android уместиться в небольшой объём памяти. Без анимации загрузки Android стартует быстрее.")
        }
    }

    // MARK: - Specifications

    private var specsSection: some View {
        Section {
            VMSpecRow(title: "Модель", value: VMDevice.modelName)
            VMSpecRow(title: "Идентификатор", value: VMDevice.machine)
            VMSpecRow(title: "Процессор", value: VMDevice.chipName)
            VMSpecRow(title: "Ядра", value: coresText)
            VMSpecRow(title: "Оперативная память", value: "\(VMDevice.ramDescription) (\(vmFormatBytes(Int64(VMDevice.ramBytes))) доступно системе)")
            VMSpecRow(title: "Лимит памяти приложения", value: vmFormatMiB(settings.appMemoryLimitMiB))
            VMSpecRow(title: "Свободно для приложения сейчас", value: vmFormatBytes(Int64(appMemoryNow)))
            VMSpecRow(title: "Система", value: VMDevice.iosVersion)
            VMSpecRow(title: "Экран", value: "\(VMDevice.screenPixels.width)×\(VMDevice.screenPixels.height) · \(VMDevice.ppi) ppi")
            VMSpecRow(title: "Хранилище: свободно", value: vmFormatBytes(storage.free))
            VMSpecRow(title: "Хранилище: всего", value: vmFormatBytes(storage.total))
            if vm != nil {
                VMSpecRow(title: "Android занимает", value: vmFormatBytes(androidSize))
            }
            VMSpecRow(title: "JIT", value: jit.isEnabled ? "включён" : "выключен")
        } header: {
            Text("Характеристики")
        }
    }

    private var coresText: String {
        let c = VMDevice.cpuCores
        if c.performance > 0 && c.efficiency > 0 {
            return "\(c.total): \(c.performance) производительных + \(c.efficiency) энергоэффективных"
        }
        return "\(c.total)"
    }

    // MARK: - Maintenance

    private var maintenanceSection: some View {
        Section {
            Button("Как включить JIT") {
                isJITHelpShown = true
            }
            Button("Сбросить настройки") {
                isResetConfirmShown = true
            }
            .confirmationDialog("Вернуть настройки эмулятора по умолчанию?", isPresented: $isResetConfirmShown, titleVisibility: .visible) {
                Button("Сбросить", role: .destructive) {
                    settings.resetToDefaults()
                }
            }
            if let vm = vm {
                Button("Удалить Android", role: .destructive) {
                    isDeleteConfirmShown = true
                }
                .confirmationDialog("Удалить Android вместе со всеми его данными и приложениями? Это нельзя отменить.", isPresented: $isDeleteConfirmShown, titleVisibility: .visible) {
                    Button("Удалить", role: .destructive) {
                        shell.delete(vm: vm, data: data)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            refresh()
                        }
                    }
                }
            }
        } header: {
            Text("Обслуживание")
        }
    }

    private func refresh() {
        storage = VMDevice.storage()
        appMemoryNow = VMDevice.appMemoryAvailable
        jit.refresh()
        if let vm = vm {
            let size = shell.androidSizeOnDisk(vm)
            androidSize = size
        }
    }
}

private struct VMSpecRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
