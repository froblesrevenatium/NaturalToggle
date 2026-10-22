import AppKit
import IOKit
import IOKit.hid

struct Config {
    var vendorID = 2821
    var productID = 6304

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--vendor": vendorID = iterator.next().flatMap { Int($0) } ?? vendorID
            case "--product": productID = iterator.next().flatMap { Int($0) } ?? productID
            default: break
            }
        }
    }

    func matchingDictionary() -> CFMutableDictionary {
        let dictionary = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        dictionary[kIOHIDVendorIDKey] = vendorID
        dictionary[kIOHIDProductIDKey] = productID
        return dictionary as CFMutableDictionary
    }
}

enum NaturalScroll {
    private typealias Setter = @convention(c) (Bool) -> Void
    private typealias Getter = @convention(c) () -> Bool

    private static let handle = dlopen("/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/PreferencePanesSupport", RTLD_LAZY)

    private static let setter: Setter? = dlsym(handle, "setSwipeScrollDirection").map { unsafeBitCast($0, to: Setter.self) }
    private static let getter: Getter? = dlsym(handle, "swipeScrollDirection").map { unsafeBitCast($0, to: Getter.self) }

    static var isEnabled: Bool? { getter?() }

    static func set(_ enabled: Bool) {
        guard let setter else {
            log("setSwipeScrollDirection no disponible")
            return
        }
        setter(enabled)
    }
}

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardOutput.write("\(timestamp) \(message)\n".data(using: .utf8)!)
}

final class MouseWatcher {
    private let config: Config
    private let port = IONotificationPortCreate(kIOMainPortDefault)
    private var iterators: [io_iterator_t] = []
    private var lastConnected: Bool?
    var onChange: ((Bool) -> Void)?

    init(config: Config) {
        self.config = config
    }

    func start() {
        IONotificationPortSetDispatchQueue(port, .main)
        register(kIOFirstMatchNotification)
        register(kIOTerminatedNotification)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastConnected = nil
            self?.evaluate()
        }
        evaluate()
    }

    private func register(_ type: String) {
        var iterator: io_iterator_t = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, type, config.matchingDictionary(), { context, iterator in
            drain(iterator)
            guard let context else { return }
            Unmanaged<MouseWatcher>.fromOpaque(context).takeUnretainedValue().evaluate()
        }, context, &iterator)
        guard result == KERN_SUCCESS else {
            log("No se pudo registrar \(type): \(result)")
            exit(1)
        }
        drain(iterator)
        iterators.append(iterator)
    }

    private func isMouseConnected() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, config.matchingDictionary(), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    private func evaluate() {
        let connected = isMouseConnected()
        guard connected != lastConnected else { return }
        lastConnected = connected
        let natural = !connected
        if NaturalScroll.isEnabled != natural {
            NaturalScroll.set(natural)
        }
        log("Mouse \(connected ? "conectado" : "desconectado") -> desplazamiento natural \(natural ? "encendido" : "apagado")")
        onChange?(connected)
    }
}

func drain(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 {
        IOObjectRelease(service)
    }
}

final class StatusBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let config: Config
    private let mouseItem = NSMenuItem()
    private let scrollItem = NSMenuItem()
    private var connected = false

    init(config: Config) {
        self.config = config
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        mouseItem.isEnabled = false
        scrollItem.isEnabled = false
        let deviceItem = NSMenuItem(title: "Vendor \(config.vendorID) · Product \(config.productID)", action: nil, keyEquivalent: "")
        deviceItem.isEnabled = false
        menu.addItem(withTitle: "Auto Scroll Mode activo", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(mouseItem)
        menu.addItem(scrollItem)
        menu.addItem(deviceItem)
        menu.addItem(.separator())
        menu.addItem(target(NSMenuItem(title: "Configurar…", action: #selector(openSettings), keyEquivalent: ",")))
        menu.addItem(target(NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q")))
        item.menu = menu
        update(connected: false)
    }

    func update(connected: Bool) {
        self.connected = connected
        let symbol = connected ? "computermouse.fill" : "computermouse"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Auto Scroll Mode")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = !connected
        item.button?.toolTip = "Auto Scroll Mode · mouse \(connected ? "conectado" : "desconectado")"
        refreshMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    private func refreshMenu() {
        mouseItem.title = "Mouse: \(connected ? "conectado" : "desconectado")"
        let natural = NaturalScroll.isEnabled.map { $0 ? "encendido" : "apagado" } ?? "desconocido"
        scrollItem.title = "Desplazamiento natural: \(natural)"
    }

    private func target(_ menuItem: NSMenuItem) -> NSMenuItem {
        menuItem.target = self
        return menuItem
    }

    @objc private func openSettings() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.fernandorobles.auto-scrollmode-changer.app") else {
            log("No se encontró Auto Scroll Mode.app")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() {
        log("Detenido desde la barra de menús")
        exit(0)
    }
}

let config = Config(arguments: CommandLine.arguments)
log("Vigilando mouse vendor=\(config.vendorID) product=\(config.productID)")
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let statusBar = StatusBar(config: config)
let watcher = MouseWatcher(config: config)
watcher.onChange = { statusBar.update(connected: $0) }
watcher.start()
application.run()
