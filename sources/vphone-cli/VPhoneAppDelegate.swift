import AppKit
import Foundation
import Virtualization

class VPhoneAppDelegate: NSObject, NSApplicationDelegate {
    private let cli: VPhoneBootCLI
    private var vm: VPhoneVirtualMachine?
    private var control: VPhoneControl?
    private var windowController: VPhoneWindowController?
    private var menuController: VPhoneMenuController?
    private var fileWindowController: VPhoneFileWindowController?
    private var keychainWindowController: VPhoneKeychainWindowController?
    private var appWindowController: VPhoneAppWindowController?
    private var instanceWindowController: VPhoneInstanceWindowController?
    private var locationProvider: VPhoneLocationProvider?
    private var hostControl: VPhoneHostControl?
    private var sigintSource: DispatchSourceSignal?
    private var didAttemptAutoInstall = false

    init(cli: VPhoneBootCLI) {
        self.cli = cli
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        // The VM host process must stay alive even when its window is hidden or
        // the launcher script exits.  AppKit automatic/sudden termination can
        // otherwise reap a windowless background app, leaving stale sockets and
        // confusing the multi-instance manager.
        ProcessInfo.processInfo.disableAutomaticTermination("vphone VM is running")
        ProcessInfo.processInfo.disableSuddenTermination()

        // Make sidebar icon tooltips appear quickly. This is app-local via UserDefaults,
        // not a global macOS defaults write. Value is in milliseconds.
        UserDefaults.standard.set(120, forKey: "NSInitialToolTipDelay")

        NSApp.setActivationPolicy(cli.noGraphics ? .prohibited : .regular)

        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            print("\n[vphone] SIGINT — shutting down")
            NSApp.terminate(nil)
        }
        src.activate()
        sigintSource = src

        Task { @MainActor in
            do {
                try await self.startVirtualMachine()
            } catch {
                print("[vphone] Fatal: \(error)")
                exit(EXIT_FAILURE)
            }
        }
    }

    @MainActor
    private func startVirtualMachine() async throws {
        let options = try cli.resolveOptions()

        guard options.romURL == nil || FileManager.default.fileExists(atPath: options.romURL!.path) else {
            throw VPhoneError.romNotFound(options.romURL!.path)
        }

        print("=== vphone-cli ===")
        print("Variant : \(options.variant)")
        print("ROM     : \(options.romURL?.path ?? "None")")
        print("Disk    : \(options.diskURL.path)")
        print("NVRAM   : \(options.nvramURL.path)")
        print("Config  : \(options.configURL.path)")
        print("CPU     : \(options.cpuCount)")
        print("Memory  : \(options.memorySize / 1024 / 1024) MB")
        print(
            "Screen: \(options.screenWidth)x\(options.screenHeight) @ \(options.screenPPI) PPI (scale \(options.screenScale)x)"
        )
        if let kernelDebugPort = options.kernelDebugPort {
            print("Kernel debug stub : 127.0.0.1:\(kernelDebugPort)")
        } else {
            print("Kernel debug stub : auto-assigned")
        }
        print("SEP               : enabled")
        print("  storage         : \(options.sepStorageURL.path)")
        print("  rom             : \(options.sepRomURL?.path ?? "None")")
        print("")

        let vm = try VPhoneVirtualMachine(options: options)
        self.vm = vm

        try await vm.start(forceDFU: cli.dfu)

        let control = VPhoneControl(variant: options.variant)
        self.control = control
        if !cli.dfu {
            let vphonedURL = URL(fileURLWithPath: cli.vphonedBin)
            if FileManager.default.fileExists(atPath: vphonedURL.path) {
                control.guestBinaryURL = vphonedURL
            }

            let provider = VPhoneLocationProvider(control: control)
            locationProvider = provider

            if let device = vm.virtualMachine.socketDevices.first as? VZVirtioSocketDevice {
                control.connect(device: device)
            }
        }

        if !cli.noGraphics {
            let keyHelper = VPhoneKeyHelper(vm: vm, control: control)
            let wc = VPhoneWindowController()
            wc.showWindow(
                for: vm.virtualMachine,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight,
                screenScale: options.screenScale,
                keyHelper: keyHelper,
                control: control,
                ecid: vm.ecidHex
            )
            windowController = wc

            let fileWC = VPhoneFileWindowController()
            fileWindowController = fileWC

            let keychainWC = VPhoneKeychainWindowController()
            keychainWindowController = keychainWC

            let appWC = VPhoneAppWindowController()
            appWindowController = appWC

            let projectRootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let instanceWC = VPhoneInstanceWindowController(projectRootURL: projectRootURL)
            instanceWindowController = instanceWC

            let mc = VPhoneMenuController(keyHelper: keyHelper, control: control)
            mc.vm = vm
            mc.vmDirectoryURL = options.configURL.deletingLastPathComponent()
            mc.projectRootURL = projectRootURL
            mc.captureView = wc.captureView
            mc.touchIDMonitor = wc.touchIDMonitor
            mc.onFilesPressed = { [weak fileWC, weak control] in
                guard let fileWC, let control else { return }
                fileWC.showWindow(control: control)
            }
            mc.onKeychainPressed = { [weak keychainWC, weak control] in
                guard let keychainWC, let control else { return }
                keychainWC.showWindow(control: control)
            }
            mc.onAppsPressed = { [weak appWC, weak control] in
                guard let appWC, let control else { return }
                appWC.showWindow(control: control)
            }
            mc.onInstanceManagerPressed = { [weak instanceWC] in
                instanceWC?.showWindow()
            }
            if let provider = locationProvider {
                mc.locationProvider = provider
            }
            let recorder = VPhoneScreenRecorder()
            mc.screenRecorder = recorder
            menuController = mc

            wc.onInstallPackagePressed = { [weak mc] in mc?.installIPAFromDisk() }
            wc.onImportPhotoPressed = { [weak mc] in mc?.importPhotoToAlbum() }
            wc.onTypeASCIIPressed = { [weak mc] in mc?.typeFromClipboard() }
            wc.onDeletePhotosPressed = { [weak mc] in mc?.deleteAllPhotosFromAlbum() }
            wc.onScreenshotPressed = { [weak mc] in mc?.saveScreenshotToFile() }
            wc.onRebootPressed = { [weak mc] in mc?.rebootGuest() }
            wc.onRespringPressed = { [weak mc] in mc?.respringGuest() }
            wc.onConnectionInfoPressed = { [weak mc] in mc?.showConnectionInfo() }

            let socketPath = options.configURL
                .deletingLastPathComponent()
                .appendingPathComponent("vphone.sock").path
            let hc = VPhoneHostControl(socketPath: socketPath)
            hc.start(
                captureView: wc.captureView!,
                screenRecorder: recorder,
                control: control,
                keyHelper: keyHelper,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight,
                showWindow: { [weak wc] in
                    wc?.showExistingWindow()
                }
            )
            hostControl = hc

            // Wire location toggle through onConnect/onDisconnect
            control.onConnect = { [weak mc, weak wc, weak provider = locationProvider] caps in
                mc?.updateConnectAvailability(available: true)
                mc?.updateInstallAvailability(available: caps.contains("ipa_install"))
                mc?.updateAppsAvailability(available: caps.contains("apps"))
                mc?.updateURLAvailability(available: caps.contains("url"))
                mc?.updateClipboardAvailability(available: caps.contains("clipboard"))
                mc?.updateSettingsAvailability(available: true)
                if caps.contains("location") {
                    mc?.updateLocationCapability(available: true)
                    // Auto-resume if user had toggle on
                    if mc?.locationMenuItem?.state == .on {
                        provider?.startForwarding()
                    }
                } else {
                    print("[location] guest does not support location simulation")
                }
                mc?.syncBatteryFromHost()
                mc?.syncLowPowerModeFromHost()
                wc?.updateToolbarAvailability(
                    connected: true, canInstallPackage: caps.contains("ipa_install")
                )
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak mc, weak wc, weak provider = locationProvider] in
                mc?.updateConnectAvailability(available: false)
                mc?.updateInstallAvailability(available: false)
                mc?.updateAppsAvailability(available: false)
                mc?.updateURLAvailability(available: false)
                mc?.updateClipboardAvailability(available: false)
                mc?.updateSettingsAvailability(available: false)
                provider?.stopReplay()
                provider?.stopForwarding()
                mc?.updateLocationCapability(available: false)
                wc?.updateToolbarAvailability(connected: false, canInstallPackage: false)
            }
        } else if !cli.dfu {
            // Headless mode: auto-start location as before (no menu exists)
            control.onConnect = { [weak provider = locationProvider] caps in
                if caps.contains("location") {
                    provider?.startForwarding()
                } else {
                    print("[location] guest does not support location simulation")
                }
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak provider = locationProvider] in
                provider?.stopReplay()
                provider?.stopForwarding()
            }
        }
    }

    @MainActor
    private func installPackageIfRequested(caps: [String]) async {
        guard !didAttemptAutoInstall else { return }
        guard let packageURL = cli.installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            didAttemptAutoInstall = true
            print("[install] requested package not found: \(packageURL.path)")
            return
        }
        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            didAttemptAutoInstall = true
            print("[install] unsupported package type: \(packageURL.path)")
            return
        }
        guard caps.contains("ipa_install") else {
            print(
                "[install] guest does not advertise ipa_install; reconnect or reboot the guest so the updated daemon can take over"
            )
            return
        }
        guard let control else {
            print("[install] control channel is not ready")
            return
        }

        didAttemptAutoInstall = true
        print("[install] auto-installing \(packageURL.lastPathComponent)")
        do {
            let result = try await control.installIPA(localURL: packageURL)
            print("[install] \(result)")
        } catch {
            print("[install] failed: \(error)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        hostControl?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // Closing the VM GUI window should only hide the GUI and keep the
        // virtual phone alive for background automation/multi-instance use.
        // Real shutdown is handled by scripts/stop_vphone_instance.sh or Cmd-Q.
        false
    }
}
