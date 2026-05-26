import Cocoa

// MARK: - Memory data

struct MemStats {
    let total: UInt64
    let free: UInt64
    let used: UInt64        // raw: everything not free (includes cache)
    let realUsed: UInt64    // app + wired + compressed — actually unavailable
    let available: UInt64   // free + cached — what apps can actually grab
    let wired: UInt64
    let active: UInt64
    let compressor: UInt64
    let app: UInt64
    let cached: UInt64
    var realUsedPercent: Double { Double(realUsed) / Double(total) * 100 }
}

struct SwapStats {
    let total: UInt64
    let used: UInt64
    let free: UInt64
}

struct ProcInfo {
    let pid: Int
    let rssBytes: UInt64
    let name: String
}

func pageSize() -> UInt64 {
    var size: vm_size_t = 0
    host_page_size(mach_host_self(), &size)
    return UInt64(size)
}

func totalMemory() -> UInt64 {
    var size: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &size, &len, nil, 0)
    return size
}

func getMemStats() -> MemStats {
    let pageSize = pageSize()
    let total = totalMemory()

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else {
        return MemStats(total: total, free: 0, used: total, realUsed: total, available: 0,
                        wired: 0, active: 0, compressor: 0, app: 0, cached: 0)
    }

    let free = (UInt64(stats.free_count) + UInt64(stats.speculative_count)) * pageSize
    let active = UInt64(stats.active_count) * pageSize
    let wired = UInt64(stats.wire_count) * pageSize
    let compressor = UInt64(stats.compressor_page_count) * pageSize
    let purgeable = UInt64(stats.purgeable_count) * pageSize
    let external = UInt64(stats.external_page_count) * pageSize
    let internalPages = UInt64(stats.internal_page_count) * pageSize

    let app = internalPages > purgeable ? (internalPages - purgeable) : 0
    let cached = external + purgeable
    let used = total > free ? (total - free) : 0
    let realUsed = app + wired + compressor
    let available = total > realUsed ? (total - realUsed) : 0

    return MemStats(total: total, free: free, used: used, realUsed: realUsed, available: available,
                    wired: wired, active: active, compressor: compressor, app: app, cached: cached)
}

func getSwapStats() -> SwapStats {
    var xsw = xsw_usage()
    var len = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &xsw, &len, nil, 0)
    return SwapStats(total: xsw.xsu_total, used: xsw.xsu_used, free: xsw.xsu_avail)
}

func getTopProcesses(limit: Int = 10) -> [ProcInfo] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "pid=,rss=,comm="]
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    do {
        try task.run()
    } catch {
        return []
    }
    // Read BEFORE waiting — otherwise ps blocks on a full pipe and we deadlock
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var procs: [ProcInfo] = []
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3,
              let pid = Int(parts[0]),
              let rssKB = UInt64(parts[1]) else { continue }
        var name = String(parts[2])
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        procs.append(ProcInfo(pid: pid, rssBytes: rssKB * 1024, name: name))
    }
    procs.sort { $0.rssBytes > $1.rssBytes }
    return Array(procs.prefix(limit))
}

// MARK: - Formatting

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824.0
    if gb >= 1.0 { return String(format: "%.2f GB", gb) }
    let mb = Double(bytes) / 1_048_576.0
    return String(format: "%.0f MB", mb)
}

func padRight(_ s: String, _ width: Int) -> String {
    if s.count >= width { return s }
    return s + String(repeating: " ", count: width - s.count)
}

func padLeft(_ s: String, _ width: Int) -> String {
    if s.count >= width { return s }
    return String(repeating: " ", count: width - s.count) + s
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "RAM")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        refreshTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
    }

    func refreshTitle() {
        let stats = getMemStats()
        statusItem.button?.title = " \(Int(stats.realUsedPercent.rounded()))%"
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    func rebuildMenu() {
        menu.removeAllItems()

        let mem = getMemStats()
        let swap = getSwapStats()
        let procs = getTopProcesses(limit: 10)

        addInfo("Used       \(formatBytes(mem.realUsed)) / \(formatBytes(mem.total))  (\(Int(mem.realUsedPercent.rounded()))%)")
        addInfo("Available  \(formatBytes(mem.available))")
        menu.addItem(.separator())
        addInfo("  App         \(formatBytes(mem.app))")
        addInfo("  Wired       \(formatBytes(mem.wired))")
        addInfo("  Compressed  \(formatBytes(mem.compressor))")
        addInfo("  Cached      \(formatBytes(mem.cached))")
        addInfo("  Free        \(formatBytes(mem.free))")

        menu.addItem(.separator())

        if swap.total == 0 {
            addInfo("Swap  не используется")
        } else {
            addInfo("Swap  \(formatBytes(swap.used)) / \(formatBytes(swap.total))")
        }

        menu.addItem(.separator())

        addHeader("Top processes by RAM")
        for p in procs {
            let line = "\(padLeft(formatBytes(p.rssBytes), 9))  \(p.name)"
            addInfo(line)
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh", action: #selector(rebuildMenuAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func rebuildMenuAction() {
        rebuildMenu()
        refreshTitle()
    }

    func addInfo(_ text: String) {
        menu.addItem(makeViewItem(text: text,
                                  font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)))
    }

    func addHeader(_ text: String) {
        menu.addItem(makeViewItem(text: text,
                                  font: NSFont.systemFont(ofSize: 12, weight: .semibold)))
    }

    func makeViewItem(text: String, font: NSFont) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = true

        let leftPad: CGFloat = 14
        let rightPad: CGFloat = 14
        let width: CGFloat = 380
        let height: CGFloat = 20

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byClipping
        label.frame = NSRect(x: leftPad, y: 2,
                             width: width - leftPad - rightPad,
                             height: height - 4)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.addSubview(label)

        item.view = container
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
