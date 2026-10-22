import SwiftUI
import IOKit
import IOKit.hid

struct Mouse: Identifiable, Hashable {
    let name: String
    let vendorID: Int
    let productID: Int
    let transport: String

    var id: String { "\(vendorID):\(productID)" }
}

enum MouseScanner {
    static func connectedMice() -> [Mouse] {
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Mouse
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var mice: [String: Mouse] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let vendorID = property(kIOHIDVendorIDKey) as? Int,
                  let productID = property(kIOHIDProductIDKey) as? Int else { continue }
            let mouse = Mouse(
                name: property(kIOHIDProductKey) as? String ?? "Desconocido",
                vendorID: vendorID,
                productID: productID,
                transport: property(kIOHIDTransportKey) as? String ?? "-"
            )
            mice[mouse.id] = mouse
        }
        return mice.values.sorted { $0.name < $1.name }
    }
}

struct InstalledConfig: Equatable {
    let vendorID: Int
    let productID: Int
}

enum Agent {
    static let name = "auto-scrollmode-changer"
    static let label = "com.fernandorobles.\(name)"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let binary = home.appendingPathComponent(".local/bin/\(name)")
    static let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static let log = home.appendingPathComponent("Library/Logs/\(name).log")
    static var domain: String { "gui/\(getuid())" }

    static var bundledBinary: URL? {
        Bundle.main.url(forResource: name, withExtension: nil)
    }

    static func installedConfig() -> InstalledConfig? {
        guard let data = try? Data(contentsOf: plist),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String] else { return nil }
        func value(after flag: String) -> Int? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return Int(arguments[index + 1])
        }
        guard let vendorID = value(after: "--vendor"), let productID = value(after: "--product") else { return nil }
        return InstalledConfig(vendorID: vendorID, productID: productID)
    }

    static func isRunning() -> Bool {
        run("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0
    }

    static func install(vendorID: Int, productID: Int) throws {
        guard let source = bundledBinary else { throw message("No se encontró el binario dentro de la app") }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: binary.path) {
            try fileManager.removeItem(at: binary)
        }
        try fileManager.copyItem(at: source, to: binary)
        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary.path, "--vendor", "\(vendorID)", "--product", "\(productID)"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: plist)
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let result = run("/bin/launchctl", ["bootstrap", domain, plist.path])
        guard result.status == 0 else { throw message("launchctl bootstrap falló: \(result.output)") }
    }

    static func uninstall() throws {
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let fileManager = FileManager.default
        for url in [plist, binary] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    static func lastLogLines(_ count: Int = 8) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    private static func message(_ text: String) -> NSError {
        NSError(domain: name, code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var mice: [Mouse] = []
    @Published var selection: Mouse.ID?
    @Published var installed: InstalledConfig?
    @Published var running = false
    @Published var log = ""
    @Published var feedback = ""

    func refresh() {
        mice = MouseScanner.connectedMice()
        installed = Agent.installedConfig()
        running = Agent.isRunning()
        log = Agent.lastLogLines()
        if selection == nil || !mice.contains(where: { $0.id == selection }) {
            selection = mice.first { isInstalled($0) }?.id ?? mice.first?.id
        }
    }

    func isInstalled(_ mouse: Mouse) -> Bool {
        installed == InstalledConfig(vendorID: mouse.vendorID, productID: mouse.productID)
    }

    func installSelected() {
        guard let mouse = mice.first(where: { $0.id == selection }) else { return }
        do {
            try Agent.install(vendorID: mouse.vendorID, productID: mouse.productID)
            feedback = "Instalado para \(mouse.name)"
        } catch {
            feedback = error.localizedDescription
        }
        refreshAfterLaunch()
    }

    func uninstall() {
        do {
            try Agent.uninstall()
            feedback = "Desinstalado"
        } catch {
            feedback = error.localizedDescription
        }
        refresh()
    }

    private func refreshAfterLaunch() {
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            refresh()
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            status

            Text("Mouse conectados").font(.headline)
            Table(model.mice, selection: $model.selection) {
                TableColumn("Nombre") { mouse in
                    HStack {
                        Text(mouse.name)
                        if model.isInstalled(mouse) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                TableColumn("Vendor") { Text(String($0.vendorID)) }.width(70)
                TableColumn("Product") { Text(String($0.productID)) }.width(70)
                TableColumn("Conexión") { Text($0.transport) }.width(80)
            }
            .frame(minHeight: 140)

            HStack {
                Button("Actualizar lista") { model.refresh() }
                Spacer()
                Button("Desinstalar", role: .destructive) { model.uninstall() }
                    .disabled(model.installed == nil && !model.running)
                Button("Usar este mouse") { model.installSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selection == nil)
            }

            if !model.feedback.isEmpty {
                Text(model.feedback).font(.callout).foregroundStyle(.secondary)
            }

            Text("Registro").font(.headline)
            ScrollView {
                Text(model.log.isEmpty ? "Sin registros" : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 110)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { model.refresh() }
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.running ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(model.running ? "Servicio activo" : "Servicio detenido").font(.headline)
            if let installed = model.installed {
                Text("· vendor \(String(installed.vendorID)), product \(String(installed.productID))")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@main
struct AutoScrollModeApp: App {
    var body: some Scene {
        WindowGroup("Auto Scroll Mode") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
