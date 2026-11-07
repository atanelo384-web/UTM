//
// VM — a single-purpose shell around UTM that boots Android full screen.
// Based on UTM (Apache-2.0), see LICENSE in the repository root.
//

import SwiftUI
import UIKit
import Darwin
import os

// MARK: - Device information

enum VMDevice {
    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    static func sysctlInt(_ name: String) -> Int {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return Int(value)
    }

    /// e.g. "iPhone11,8"
    static var machine: String { sysctlString("hw.machine") }

    private static let models: [String: (name: String, ppi: Int)] = [
        "iPhone11,8": ("iPhone XR", 326),
        "iPhone11,2": ("iPhone XS", 458),
        "iPhone11,4": ("iPhone XS Max", 458),
        "iPhone11,6": ("iPhone XS Max", 458),
        "iPhone12,1": ("iPhone 11", 326),
        "iPhone12,3": ("iPhone 11 Pro", 458),
        "iPhone12,5": ("iPhone 11 Pro Max", 458),
        "iPhone12,8": ("iPhone SE (2-го поколения)", 326),
        "iPhone13,1": ("iPhone 12 mini", 476),
        "iPhone13,2": ("iPhone 12", 460),
        "iPhone13,3": ("iPhone 12 Pro", 460),
        "iPhone13,4": ("iPhone 12 Pro Max", 458),
        "iPhone14,4": ("iPhone 13 mini", 476),
        "iPhone14,5": ("iPhone 13", 460),
        "iPhone14,2": ("iPhone 13 Pro", 460),
        "iPhone14,3": ("iPhone 13 Pro Max", 458),
        "iPhone14,6": ("iPhone SE (3-го поколения)", 326),
        "iPhone14,7": ("iPhone 14", 460),
        "iPhone14,8": ("iPhone 14 Plus", 458),
        "iPhone15,2": ("iPhone 14 Pro", 460),
        "iPhone15,3": ("iPhone 14 Pro Max", 460),
        "iPhone15,4": ("iPhone 15", 460),
        "iPhone15,5": ("iPhone 15 Plus", 460),
        "iPhone16,1": ("iPhone 15 Pro", 460),
        "iPhone16,2": ("iPhone 15 Pro Max", 460),
    ]

    @MainActor static var modelName: String {
        models[machine]?.name ?? (machine.isEmpty ? UIDevice.current.model : machine)
    }

    /// Pixels per inch of the built-in screen.
    @MainActor static var ppi: Int {
        models[machine]?.ppi ?? Int((UIScreen.main.nativeScale * 163).rounded())
    }

    static var chipName: String {
        let m = machine
        let table: [(String, String)] = [
            ("iPhone11,", "Apple A12 Bionic"),
            ("iPhone12,", "Apple A13 Bionic"),
            ("iPhone13,", "Apple A14 Bionic"),
            ("iPhone14,", "Apple A15 Bionic"),
            ("iPhone15,", "Apple A16 Bionic"),
            ("iPhone16,", "Apple A17 Pro"),
            ("iPhone17,", "Apple A18"),
        ]
        if m == "iPhone14,7" || m == "iPhone14,8" { return "Apple A15 Bionic" }
        if m == "iPhone15,4" || m == "iPhone15,5" { return "Apple A16 Bionic" }
        return table.first { m.hasPrefix($0.0) }?.1 ?? "Apple"
    }

    static var cpuCores: (total: Int, performance: Int, efficiency: Int) {
        let total = ProcessInfo.processInfo.processorCount
        let p = sysctlInt("hw.perflevel0.physicalcpu")
        let e = sysctlInt("hw.perflevel1.physicalcpu")
        return (total, p, e)
    }

    static var cpuDescription: String {
        let c = cpuCores
        if c.performance > 0 && c.efficiency > 0 {
            return "\(chipName) · \(c.total) ядер (\(c.performance) произв. + \(c.efficiency) энергоэфф.)"
        }
        return "\(chipName) · \(c.total) ядер"
    }

    static var ramBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Marketing size, e.g. 3 GB for a phone that reports 2.8 GiB.
    static var ramDescription: String {
        let gib = Double(ramBytes) / 1_073_741_824
        return "\(Int(gib.rounded(.up))) ГБ"
    }

    @MainActor static var iosVersion: String { "iOS \(UIDevice.current.systemVersion)" }

    /// Bytes this process may still allocate before iOS terminates it.
    static var appMemoryAvailable: Int { Int(os_proc_available_memory()) }

    static func storage() -> (free: Int64, total: Int64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        return (free, total)
    }

    @MainActor static var screenPixels: (width: Int, height: Int) {
        let b = UIScreen.main.nativeBounds.size
        let w = Int(min(b.width, b.height)), h = Int(max(b.width, b.height))
        return (w, h)
    }
}

func vmFormatBytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    if gb >= 10 { return String(format: "%.0f ГБ", gb) }
    if gb >= 1 { return String(format: "%.1f ГБ", gb).replacingOccurrences(of: ".", with: ",") }
    return String(format: "%.0f МБ", Double(bytes) / 1_000_000)
}

func vmFormatMiB(_ mib: Int) -> String {
    if mib >= 1024 && mib % 256 == 0 {
        let g = Double(mib) / 1024
        let s = g == g.rounded() ? String(format: "%.0f", g) : String(format: "%.2f", g).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
        return s.replacingOccurrences(of: ".", with: ",") + " ГБ"
    }
    return "\(mib) МБ"
}

// MARK: - Android image

enum VMAndroidImage {
    /// LineageOS for QEMU/UTM by jqssun. v2026.10.18 is the last release that works with UTM's QEMU.
    static let downloadURL = URL(string: "https://github.com/jqssun/android-lineage-qemu/releases/download/v2026.10.18/UTM-VM-lineage-23.2-20261019-jqssun-virtio_arm64only.zip")!
    static let downloadSize: Int64 = 1_121_501_784
    static let unpackedSize: Int64 = 2_256_477_261
    /// Byte offset of the GRUB environment block inside Data/vda.qcow2 of that exact release.
    static let knownGrubEnvOffset: UInt64 = 0x86303200
}

/// Name and version of the installed Android, read from the VM notes written by the LineageOS build.
struct VMAndroidInfo {
    var distribution: String
    var version: String
    var android: String

    @MainActor init(config: UTMQemuConfiguration?) {
        let notes = config?.information.notes ?? ""
        var lineage = ""
        for line in notes.components(separatedBy: .newlines) where line.contains("Initial version:") {
            let v = line.components(separatedBy: "Initial version:").last?.trimmingCharacters(in: .whitespaces) ?? ""
            lineage = v.components(separatedBy: "-").first ?? ""
        }
        if lineage.isEmpty, let name = config?.information.name, name.localizedCaseInsensitiveContains("lineage") {
            lineage = "?"
        }
        distribution = lineage.isEmpty ? "Android" : "LineageOS"
        version = lineage == "?" ? "" : lineage
        let major = Int(lineage.components(separatedBy: ".").first ?? "") ?? 0
        let map = [17: "10", 18: "11", 19: "12", 20: "13", 21: "14", 22: "15", 23: "16", 24: "17"]
        android = map[major].map { "Android \($0)" } ?? "Android"
    }

    var title: String { version.isEmpty ? distribution : "\(distribution) \(version)" }
}

// MARK: - Settings

enum VMResolution: String, CaseIterable, Identifiable {
    case native
    case half
    var id: String { rawValue }

    @MainActor var size: (width: Int, height: Int) {
        let s = VMDevice.screenPixels
        switch self {
        case .native: return s
        case .half: return (s.width / 2, s.height / 2)
        }
    }

    @MainActor var density: Int {
        switch self {
        case .native: return VMDevice.ppi
        case .half: return VMDevice.ppi / 2
        }
    }

    @MainActor var title: String {
        let s = size
        return "\(s.width)×\(s.height) · \(density) ppi"
    }

    var subtitle: String {
        switch self {
        case .native: return "Как у экрана iPhone"
        case .half: return "Вдвое меньше пикселей — быстрее"
        }
    }
}

@MainActor
final class VMShellSettings: ObservableObject {
    static let shared = VMShellSettings()
    private let d = UserDefaults.standard

    @Published var memoryMiB: Int { didSet { d.set(memoryMiB, forKey: "vm.memory") } }
    @Published var cpuCount: Int { didSet { d.set(cpuCount, forKey: "vm.cpus") } }
    @Published var jitCacheMiB: Int { didSet { d.set(jitCacheMiB, forKey: "vm.jitcache") } }
    @Published var resolution: VMResolution { didSet { d.set(resolution.rawValue, forKey: "vm.resolution") } }
    @Published var gpuAcceleration: Bool { didSet { d.set(gpuAcceleration, forKey: "vm.gpu") } }
    @Published var sound: Bool { didSet { d.set(sound, forKey: "vm.sound") } }
    @Published var network: Bool { didSet { d.set(network, forKey: "vm.network") } }
    @Published var fpsLimit: Int { didSet { d.set(fpsLimit, forKey: "vm.fps") } }
    @Published var bootAnimation: Bool { didSet { d.set(bootAnimation, forKey: "vm.bootanim") } }
    @Published var lowPerformanceMode: Bool { didSet { d.set(lowPerformanceMode, forKey: "vm.lowperf") } }
    @Published var zram: Bool { didSet { d.set(zram, forKey: "vm.zram") } }
    @Published var darkTheme: Bool { didSet { d.set(darkTheme, forKey: "vm.dark") } }

    static let memoryChoices = [768, 1024, 1280, 1536, 1792, 2048, 2560, 3072]
    static let cpuChoices = [1, 2, 3, 4, 6]
    static let jitChoices = [128, 192, 256, 384, 512]
    static let fpsChoices = [0, 30, 60]

    /// Memory iOS lets this app use, measured once at launch while the app is still small.
    let appMemoryLimitMiB: Int

    private init() {
        appMemoryLimitMiB = VMDevice.appMemoryAvailable / 1_048_576
        memoryMiB = d.object(forKey: "vm.memory") as? Int ?? Self.recommendedMemory(limitMiB: appMemoryLimitMiB, jitMiB: 256)
        cpuCount = d.object(forKey: "vm.cpus") as? Int ?? max(1, min(2, VMDevice.cpuCores.performance))
        jitCacheMiB = d.object(forKey: "vm.jitcache") as? Int ?? 256
        resolution = VMResolution(rawValue: d.string(forKey: "vm.resolution") ?? "") ?? .native
        gpuAcceleration = d.object(forKey: "vm.gpu") as? Bool ?? true
        sound = d.object(forKey: "vm.sound") as? Bool ?? true
        network = d.object(forKey: "vm.network") as? Bool ?? true
        fpsLimit = d.object(forKey: "vm.fps") as? Int ?? 0
        bootAnimation = d.object(forKey: "vm.bootanim") as? Bool ?? false
        lowPerformanceMode = d.object(forKey: "vm.lowperf") as? Bool ?? true
        zram = d.object(forKey: "vm.zram") as? Bool ?? true
        darkTheme = d.object(forKey: "vm.dark") as? Bool ?? false
    }

    /// Overhead of QEMU, its devices and the app itself, besides guest RAM and the JIT cache.
    static let baseUsageMiB = 300

    static func recommendedMemory(limitMiB: Int, jitMiB: Int) -> Int {
        let budget = limitMiB - jitMiB - baseUsageMiB
        let fit = memoryChoices.filter { $0 <= budget }.last ?? memoryChoices[0]
        return fit
    }

    var recommendedMemoryMiB: Int { Self.recommendedMemory(limitMiB: appMemoryLimitMiB, jitMiB: jitCacheMiB) }

    var estimatedUsageMiB: Int { memoryMiB + jitCacheMiB + Self.baseUsageMiB }

    var isOverMemoryLimit: Bool { appMemoryLimitMiB > 0 && estimatedUsageMiB > appMemoryLimitMiB }

    func resetToDefaults() {
        jitCacheMiB = 256
        memoryMiB = Self.recommendedMemory(limitMiB: appMemoryLimitMiB, jitMiB: 256)
        cpuCount = max(1, min(2, VMDevice.cpuCores.performance))
        resolution = .native
        gpuAcceleration = true
        sound = true
        network = true
        fpsLimit = 0
        bootAnimation = false
        lowPerformanceMode = true
        zram = true
        darkTheme = false
    }

    /// Writes the emulator part of the settings into the VM configuration.
    func apply(to config: UTMQemuConfiguration) {
        config.system.memorySize = memoryMiB
        config.system.cpuCount = cpuCount
        config.system.jitCacheSize = jitCacheMiB
        config.system.isForceMulticore = cpuCount > 1
        config.qemu.hasHypervisor = false
        config.qemu.hasDebugLog = false
        config.qemu.hasBalloonDevice = false
        // no USB keyboard and mouse: Android then behaves like a phone with a touch screen only
        // and shows its own on-screen keyboard
        config.qemu.hasPS2Controller = true
        config.input.hasUsbSharing = false
        config.input.maximumUsbShare = 0
        if config.input.usbBusSupport == .disabled {
            config.input.usbBusSupport = .usb3_0
        }
        config.sharing.hasClipboardSharing = false
        config.sharing.directoryShareMode = .none

        let device: QEMUDisplayDevice_aarch64 = gpuAcceleration ? .virtio_gpu_gl_pci : .virtio_gpu_pci
        var display = config.displays.first ?? UTMQemuConfigurationDisplay()
        display.hardware = device
        display.isDynamicResolution = false
        display.isNativeResolution = (resolution == .native)
        display.upscalingFilter = .linear
        display.downscalingFilter = .linear
        config.displays = [display]

        let size = resolution.size
        config.qemu.additionalArguments = [
            QEMUArgument("-global"), QEMUArgument("\(device.rawValue).xres=\(size.width)"),
            QEMUArgument("-global"), QEMUArgument("\(device.rawValue).yres=\(size.height)"),
        ]

        if sound {
            if config.sound.isEmpty {
                var s = UTMQemuConfigurationSound()
                s.hardware = QEMUSoundDevice_aarch64.AC97
                config.sound = [s]
            }
        } else {
            config.sound = []
        }

        if network {
            var net = config.networks.first ?? UTMQemuConfigurationNetwork()
            net.mode = .emulated
            net.hardware = QEMUNetworkDevice_aarch64.virtio_net_pci
            net.portForward = [] // nothing on the phone should reach into Android
            config.networks = [net]
        } else {
            config.networks = []
        }
    }

    /// Settings of the Android boot loader (GRUB), which LineageOS keeps in its persist partition.
    var grubEnvironment: [(String, String)] {
        let size = resolution.size
        return [
            ("android_hwui_renderer", "skiagl"),
            ("android_insecure_adb", "0"),
            ("android_lcd_density", "\(resolution.density)"),
            ("android_low_perf", lowPerformanceMode ? "1" : "0"),
            ("android_nobootanim", bootAnimation ? "0" : "1"),
            ("android_selinux_permissive", "0"),
            ("android_theme", darkTheme ? "2" : "1"),
            ("android_wifi_impl", ""),
            ("android_zram", zram ? "1" : "0"),
            ("grub_android_default", "0"),
            ("grub_timeout", "0"),
            ("kms_display_resolution", "\(size.width)x\(size.height)"),
            ("mitigations", "off"),
            ("quiet", "1"),
            ("serial_console_function", "disable"),
            ("zram", zram ? "1" : "0"),
        ]
    }

    /// UTM's own preferences: plain touch screen input, no gestures of its own.
    func applyAppDefaults() {
        d.set(2, forKey: "MouseTouchType")        // absolute, cursor hidden
        d.set(0, forKey: "GestureLongPress")
        d.set(0, forKey: "GestureTwoTap")
        d.set(0, forKey: "GestureTwoPan")
        d.set(0, forKey: "GestureTwoScroll")
        d.set(0, forKey: "GestureThreePan")
        d.set(true, forKey: "DisableIdleTimer")
        d.set(true, forKey: "NoSaveScreenshot")
        d.set(false, forKey: "AutosaveBackground")
        d.set(false, forKey: "AutosaveLowMemory")
        d.set(false, forKey: "RunInBackground")
        d.set(true, forKey: "NoUsbPrompt")
        d.set(fpsLimit, forKey: "QEMURendererFPSLimit")
    }
}

// MARK: - GRUB environment block

enum VMGrubEnv {
    static let signature = Array("# GRUB Environment Block\n".utf8)
    static let blockSize = 1024

    enum PatchError: LocalizedError {
        case notFound
        case tooLong
        var errorDescription: String? {
            switch self {
            case .notFound: return "Не удалось найти настройки загрузчика Android в образе диска."
            case .tooLong: return "Настройки загрузчика не помещаются в блок 1 КБ."
            }
        }
    }

    static func makeBlock(_ values: [(String, String)]) throws -> [UInt8] {
        var text = "# GRUB Environment Block\n# WARNING: Do not edit this file by tools other than grub-editenv!!!\n"
        for (k, v) in values {
            text += "\(k)=\(v)\n"
        }
        var bytes = Array(text.utf8)
        guard bytes.count <= blockSize else { throw PatchError.tooLong }
        bytes += [UInt8](repeating: UInt8(ascii: "#"), count: blockSize - bytes.count)
        return bytes
    }

    /// Reads the current block and returns its values.
    static func read(diskURL: URL) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: diskURL) else { return nil }
        defer { try? handle.close() }
        guard let offset = locate(handle: handle) else { return nil }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: blockSize) else { return nil }
        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    /// Overwrites the GRUB environment block inside the (stopped) qcow2 disk in place.
    ///
    /// The block is a fixed 1 KiB file in an uncompressed cluster, so rewriting it keeps both
    /// the qcow2 and the ext4 structures intact.
    static func write(_ values: [(String, String)], diskURL: URL) throws {
        let block = try makeBlock(values)
        let handle = try FileHandle(forUpdating: diskURL)
        defer { try? handle.close() }
        guard let offset = locate(handle: handle) else { throw PatchError.notFound }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(block))
        try handle.synchronize()
    }

    private static func isEnvBlock(_ data: Data) -> Bool {
        guard data.count >= blockSize, data.starts(with: signature) else { return false }
        let text = String(decoding: data.prefix(blockSize), as: UTF8.self)
        // the main block, not the A/B boot control one
        return text.contains("grub_timeout=") || text.contains("android_lcd_density=")
    }

    private static func locate(handle: FileHandle) -> UInt64? {
        let known = VMAndroidImage.knownGrubEnvOffset
        if (try? handle.seek(toOffset: known)) != nil,
           let data = try? handle.read(upToCount: blockSize), isEnvBlock(data) {
            return known
        }
        // another image: scan the file, 8 MiB at a time with an overlap for a block on the boundary
        let chunk = 8 << 20
        var offset: UInt64 = 0
        try? handle.seek(toOffset: 0)
        while true {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: chunk + blockSize), !data.isEmpty else { break }
            var searchStart = data.startIndex
            while let r = data.range(of: Data(signature), in: searchStart..<data.endIndex) {
                let candidate = data[r.lowerBound..<min(data.endIndex, r.lowerBound + blockSize)]
                if isEnvBlock(Data(candidate)) {
                    return offset + UInt64(r.lowerBound - data.startIndex)
                }
                searchStart = r.upperBound
            }
            if data.count < chunk + blockSize { break }
            offset += UInt64(chunk)
        }
        return nil
    }
}

// MARK: - JIT

@MainActor
final class VMJIT: ObservableObject {
    static let shared = VMJIT()

    @Published private(set) var isEnabled: Bool = false
    @Published var isWaitingForStikDebug = false

    private init() {
        refresh()
    }

    /// True once a debugger (StikDebug) has attached, which lets QEMU create executable memory.
    func refresh() {
        let enabled = Main.jitAvailable || jb_has_cs_disabled()
        if enabled {
            Main.jitAvailable = true
        }
        if enabled != isEnabled {
            isEnabled = enabled
        }
    }

    var stikDebugURL: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        var c = URLComponents()
        c.scheme = "stikdebug"
        c.host = "enable-jit"
        c.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid())),
        ]
        return c.url
    }

    /// Asks StikDebug to attach. Calls back with false when StikDebug is not installed.
    func requestFromStikDebug(completion: @escaping (Bool) -> Void) {
        guard let url = stikDebugURL else {
            completion(false)
            return
        }
        UIApplication.shared.open(url, options: [:]) { ok in
            Task { @MainActor in
                self.isWaitingForStikDebug = ok
                completion(ok)
            }
        }
    }

    /// Polls for a few seconds after returning from StikDebug.
    func waitForAttach(seconds: Double = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            refresh()
            if isEnabled { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        isWaitingForStikDebug = false
        return isEnabled
    }
}

// MARK: - Controller

@MainActor
final class VMShell: ObservableObject {
    static let shared = VMShell()

    @Published var message: VMShellMessage?
    @Published var isPreparing = false

    func androidVM(in data: UTMData) -> VMData? {
        data.virtualMachines.first { vm in
            guard let config = vm.config as? UTMQemuConfiguration else { return false }
            return config.system.architecture == .aarch64
        }
    }

    func diskURL(of vm: VMData) -> URL {
        vm.pathUrl.appendingPathComponent("Data", isDirectory: true).appendingPathComponent("vda.qcow2")
    }

    func androidSizeOnDisk(_ vm: VMData) -> Int64 {
        let dataDir = vm.pathUrl.appendingPathComponent("Data", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])) ?? []
        return files.reduce(0) { sum, url in
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return sum + Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
    }

    var hasSpaceForDownload: Bool {
        VMDevice.storage().free > VMAndroidImage.downloadSize + VMAndroidImage.unpackedSize + 500_000_000
    }

    func download(into data: UTMData) {
        guard data.pendingVMs.isEmpty else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        data.downloadUTMZip(from: VMAndroidImage.downloadURL)
    }

    /// Writes the current settings into the VM and its boot loader, then boots it.
    func start(vm: VMData, data: UTMData, settings: VMShellSettings) {
        guard !isPreparing else { return }
        guard let config = vm.config as? UTMQemuConfiguration else {
            message = .error("Не удалось прочитать конфигурацию Android.")
            return
        }
        isPreparing = true
        settings.applyAppDefaults()
        settings.apply(to: config)
        let disk = diskURL(of: vm)
        let env = settings.grubEnvironment
        Task {
            defer { isPreparing = false }
            do {
                try await data.save(vm: vm)
                try await Task.detached(priority: .userInitiated) {
                    try VMGrubEnv.write(env, diskURL: disk)
                }.value
            } catch {
                message = .error(error.localizedDescription)
                return
            }
            data.run(vm: vm)
        }
    }

    func delete(vm: VMData, data: UTMData) {
        Task {
            do {
                try await data.delete(vm: vm)
            } catch {
                message = .error(error.localizedDescription)
            }
        }
    }
}

struct VMShellMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String

    static func error(_ text: String) -> VMShellMessage {
        VMShellMessage(title: "Ошибка", text: text)
    }
}
