import AppKit
import FPGABridgeCore
import SwiftUI

/// Everything the window shows. Runs follow Vivado's rules: Run Implementation runs synthesis first if it is
/// missing or out-of-date, Generate Bitstream runs whatever it needs, and changing sources or settings marks
/// finished runs out-of-date.
@MainActor
final class AppModel: ObservableObject {
    let backend: Backend
    private let persist: Bool

    // Project
    @Published private(set) var projectURL: URL?
    @Published private(set) var project: Project?
    @Published private(set) var sourceTree: [SourceNode] = []
    @Published var selectedSourceID: String?
    @Published private(set) var recentProjects: [URL] = []

    // Sheets and alerts
    @Published var showNewProject = false
    @Published var showSettings = false
    @Published var showAddSources = false
    @Published var errorMessage: String?

    // Workspace and console
    @Published var openTabs: [WorkspaceTab] = [.summary]
    @Published var selectedTab: WorkspaceTab = .summary
    @Published var consoleTab: ConsoleTab = .tclConsole
    @Published var consoleVisible = true
    @Published var logRun: RunKind = .synthesis

    // Runs
    @Published private(set) var runs: [RunKind: RunState] = [.synthesis: RunState(), .implementation: RunState()]
    @Published private(set) var bitstreamReady = false
    @Published private(set) var activeStep: RunKind?
    @Published private(set) var isRunning = false
    @Published private(set) var stepStarted: Date?
    @Published private(set) var logs: [RunKind: [ConsoleLine]] = [:]
    @Published private(set) var tclLines: [ConsoleLine] = []
    @Published private(set) var reports: [ReportEntry] = []
    @Published private(set) var timing: TimingSummary?
    @Published private(set) var utilization: UtilizationSummary?
    @Published private(set) var lastMessage = "Ready"
    @Published private(set) var lastOutcome: RunStatus?
    @Published private(set) var connection: ConnectionState = .checking

    private var runTask: Task<Void, Never>?
    private var buffers: [RunKind: LineBuffer] = [:]
    private var tclBuffer = LineBuffer()
    private var fileCache: [String: String] = [:]

    init(backend: Backend, persist: Bool) {
        self.backend = backend
        self.persist = persist
        recentProjects = loadRecents()
        tclLines = [ConsoleLine(text: "# FPGA Bridge Tcl console. Commands run in Vivado on the build machine.", kind: .output)]
    }

    static func make() -> AppModel {
        let env = ProcessInfo.processInfo.environment
        let persist = env["FPGA_BRIDGE_NO_PERSIST"] == nil
        if env["FPGA_BRIDGE_DEMO"] == nil, let config = try? BridgeConfig.load() {
            return AppModel(backend: LiveBackend(config: config), persist: persist)
        }
        let speed = Double(env["FPGA_BRIDGE_DEMO_SPEED"] ?? "") ?? 1
        return AppModel(backend: DemoBackend(speed: speed), persist: persist)
    }

    func start() async {
        connection = .checking
        connection = await backend.checkConnection()
        await applyLaunchScenario()
    }

    /// Lets screenshots and manual testing start in a given state. Not used in normal launches.
    private func applyLaunchScenario() async {
        let env = ProcessInfo.processInfo.environment
        if let path = env["FPGA_BRIDGE_OPEN"] { openProject(at: URL(fileURLWithPath: path)) }
        switch env["FPGA_BRIDGE_SCENARIO"] {
        case "wizard": showNewProject = true
        case "example": openExampleProject()
        case "built":
            openExampleProject()
            run(.bitstream)
        case "settings":
            openExampleProject()
            showSettings = true
        case "addsources", "definemodule":
            openExampleProject()
            showAddSources = true
        case "file":
            openExampleProject()
            if let top = sourceTree.first?.children?.first?.path { openFile(top) }
        default: break
        }
        if let tab = env["FPGA_BRIDGE_CONSOLE_TAB"].flatMap(ConsoleTab.init(rawValue:)) {
            while isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            consoleTab = tab
        }
    }

    // MARK: Projects

    var hasProject: Bool { project != nil }

    func openProjectWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Choose a project folder (one that contains fpga-bridge.json)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openProject(at: url) }
    }

    func openProject(at url: URL) {
        let directory = url.pathExtension == "json" ? url.deletingLastPathComponent() : url
        do {
            let loaded = try Project.load(from: directory)
            cancelRun()
            project = loaded
            projectURL = directory
            fileCache = [:]
            openTabs = [.summary]
            selectedTab = .summary
            selectedSourceID = nil
            clearRunState(message: "Ready")
            rebuildSourceTree()
            echoTcl("open_project \(directory.appendingPathComponent(Project.fileName).path)")
            addRecent(directory)
        } catch {
            errorMessage = "Couldn't open the project: \(error)"
        }
    }

    func closeProject() {
        cancelRun()
        echoTcl("close_project")
        project = nil
        projectURL = nil
        sourceTree = []
        openTabs = [.summary]
        selectedTab = .summary
    }

    func createProject(_ request: NewProjectRequest) throws {
        let directory = try ProjectCreator.create(request)
        echoTcl("create_project \(request.name) \(directory.path) -part \(request.part)")
        openProject(at: directory)
    }

    /// Vivado's "Open Example Project": a small Basys 3 design, written to disk as a normal project.
    func openExampleProject() {
        let env = ProcessInfo.processInfo.environment
        let base = env["FPGA_BRIDGE_EXAMPLES_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/FPGABridgeExamples")
        let directory = base.appendingPathComponent(DemoData.projectName)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(Project.fileName).path) {
            openProject(at: directory)
            return
        }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-bridge-example-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            var request = NewProjectRequest(name: DemoData.projectName, location: base, part: DemoData.part, board: DemoData.board)
            request.vivadoVersion = "2023.2"
            for (name, set) in DemoData.files {
                let url = staging.appendingPathComponent(name)
                try (DemoData.contents[name] ?? "").write(to: url, atomically: true, encoding: .utf8)
                switch set {
                case .design: request.designSources.append(url)
                case .constraints: request.constraints.append(url)
                case .simulation: request.simulationSources.append(url)
                }
            }
            try createProject(request)
        } catch {
            errorMessage = "Couldn't create the example project: \(error)"
        }
    }

    func addSources(_ urls: [URL], to set: SourceSet) {
        guard let projectURL else { return }
        do {
            let added = try ProjectCreator.add(urls, to: set, projectDirectory: projectURL)
            echoTcl("import_files -fileset \(set.directoryName) -norecurse {\(urls.map(\.path).joined(separator: " "))}")
            reloadProjectAfterChange()
            if let first = added.first { openFile(first) }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func createSourceFile(named name: String, in set: SourceSet, module: ModuleDefinition? = nil) {
        guard let projectURL, let project else { return }
        do {
            let path = try ProjectCreator.createFile(NewFile(set: set, name: name, module: module),
                                                     language: project.targetLanguage ?? "Verilog",
                                                     projectName: project.name, directory: projectURL, part: project.part)
            echoTcl("add_files -fileset \(set.directoryName) \(path)")
            reloadProjectAfterChange()
            openFile(path)
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Project Settings > General.
    func applySettings(top: String, part: String, board: String?, language: String, vivadoVersion: String?) {
        guard var updated = project, let projectURL else { return }
        updated.top = top
        updated.part = part
        updated.board = board
        updated.targetLanguage = language
        updated.vivadoVersion = vivadoVersion
        do {
            try updated.validate()
            try updated.save(to: projectURL)
            if updated.part != project?.part { echoTcl("set_property part \(part) [current_project]") }
            if updated.top != project?.top { echoTcl("set_property top \(top) [current_fileset]") }
            reloadProjectAfterChange()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func reloadProjectAfterChange() {
        guard let projectURL, let reloaded = try? Project.load(from: projectURL) else { return }
        project = reloaded
        fileCache = [:]
        rebuildSourceTree()
        markOutOfDate()
    }

    private func markOutOfDate() {
        for kind in [RunKind.synthesis, .implementation] where runs[kind]?.status == .complete {
            runs[kind]?.outOfDate = true
        }
    }

    private func rebuildSourceTree() {
        guard let project, let projectURL else { sourceTree = []; return }
        sourceTree = SourceTreeBuilder.build(
            top: project.top,
            design: (try? project.resolveSources(in: projectURL)) ?? [],
            constraints: (try? project.resolveConstraints(in: projectURL)) ?? [],
            simulation: (try? project.resolveSimulationSources(in: projectURL)) ?? [],
            read: contents(of:))
    }

    func contents(of path: String) -> String {
        if let cached = fileCache[path] { return cached }
        guard let projectURL else { return "" }
        let text = (try? String(contentsOf: projectURL.appendingPathComponent(path), encoding: .utf8)) ?? ""
        fileCache[path] = text
        return text
    }

    func node(withID id: String?) -> SourceNode? {
        guard let id else { return nil }
        func search(_ nodes: [SourceNode]) -> SourceNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = search(node.children ?? []) { return found }
            }
            return nil
        }
        return search(sourceTree)
    }

    // MARK: Flow Navigator

    func perform(_ item: FlowItem) {
        guard item.isAvailable, hasProject else { return }
        switch item {
        case .settings: showSettings = true
        case .addSources: showAddSources = true
        default: if let kind = item.runKind { run(kind) }
        }
    }

    /// Vivado's behavior: each step runs what it depends on if that is missing or out-of-date.
    func run(_ target: RunKind) {
        var plan: [RunKind] = []
        if target == .synthesis || runs[.synthesis]?.isUpToDate != true { plan.append(.synthesis) }
        if target == .implementation || (target == .bitstream && runs[.implementation]?.isUpToDate != true) {
            plan.append(.implementation)
        }
        if target == .bitstream { plan.append(.bitstream) }
        execute(plan)
    }

    func status(of item: FlowItem) -> RunState? {
        guard let kind = item.runKind else { return nil }
        if kind == .bitstream {
            if activeStep == .bitstream { return RunState(status: .running) }
            return bitstreamReady ? RunState(status: .complete, outOfDate: runs[.implementation]?.outOfDate ?? false) : nil
        }
        return runs[kind]
    }

    var canStop: Bool { isRunning && backend.canStop }

    func stop() {
        guard canStop else { return }
        runTask?.cancel()
    }

    func resetRuns() {
        cancelRun()
        echoTcl("reset_run synth_1")
        clearRunState(message: "Runs reset")
        openTabs.removeAll { if case .report = $0 { return true }; return false }
        if !openTabs.contains(selectedTab) { selectedTab = .summary }
    }

    /// Back to "Not started" with no logs, reports or results.
    private func clearRunState(message: String) {
        runs = [.synthesis: RunState(), .implementation: RunState()]
        bitstreamReady = false
        logs = [:]
        reports = []
        timing = nil
        utilization = nil
        lastOutcome = nil
        lastMessage = message
    }

    private func cancelRun() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        activeStep = nil
    }

    private func execute(_ plan: [RunKind]) {
        guard !isRunning, let project, let projectURL, !plan.isEmpty else { return }
        isRunning = true
        consoleVisible = true
        runTask = Task { [weak self] in
            for (index, step) in plan.enumerated() {
                guard let self, !Task.isCancelled else { break }
                // A live run completes every step at once, so later steps may already be done.
                if index > 0, self.isDone(step) { continue }
                let succeeded = await self.performStep(step, project: project, directory: projectURL)
                if !succeeded { break }
            }
            self?.activeStep = nil
            self?.stepStarted = nil
            self?.isRunning = false
            self?.runTask = nil
        }
    }

    private func isDone(_ step: RunKind) -> Bool {
        step == .bitstream ? bitstreamReady && runs[.implementation]?.isUpToDate == true : runs[step]?.isUpToDate == true
    }

    private func performStep(_ step: RunKind, project: Project, directory: URL) async -> Bool {
        let run = step.run
        activeStep = step
        logRun = run
        consoleTab = .log
        let started = Date()
        stepStarted = started

        switch step {
        case .synthesis: echoTcl("launch_runs synth_1 -jobs 4")
        case .implementation: echoTcl("launch_runs impl_1 -jobs 4")
        case .bitstream: echoTcl("launch_runs impl_1 -to_step write_bitstream -jobs 4")
        }
        if step == .bitstream {
            runs[.implementation]?.status = .running
        } else {
            logs[run] = []
            buffers[run] = LineBuffer()
            runs[run] = RunState(status: .running, started: started)
            bitstreamReady = false
        }
        lastMessage = step == .bitstream ? "Running write_bitstream on impl_1…" : "Running \(step.runName)…"

        let outcome = await backend.run(step, project: project, directory: directory) { [weak self] chunk in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ingest(chunk, into: run) } }
        }
        // Chunks are delivered through the main queue; let the ones already queued land before finishing.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
        if var buffer = buffers[run] {
            logs[run, default: []].append(contentsOf: buffer.flush().map { ConsoleLine(text: $0, kind: ConsoleLine.classify($0)) })
            buffers[run] = buffer
        }
        runs[run]?.elapsed += Date().timeIntervalSince(started)

        if outcome.cancelled {
            runs[run]?.status = .cancelled
            lastOutcome = .cancelled
            lastMessage = "\(step.runName) cancelled"
            return false
        }
        if outcome.failed || outcome.completed.isEmpty {
            runs[run]?.status = .failed
            lastOutcome = .failed
            lastMessage = "\(step == .bitstream ? "write_bitstream" : step.runName) failed. See Messages."
            consoleTab = .messages
            return false
        }

        apply(outcome)
        lastOutcome = .complete
        switch step {
        case .synthesis: lastMessage = "synth_1 complete"
        case .implementation: lastMessage = "impl_1 complete"
        case .bitstream: lastMessage = "Bitstream generated"
        }
        return true
    }

    private func apply(_ outcome: RunOutcome) {
        let synthJustRan = outcome.completed.contains(.synthesis)
        for kind in [RunKind.synthesis, .implementation] where outcome.completed.contains(kind) {
            runs[kind]?.status = .complete
            runs[kind]?.outOfDate = false
        }
        // New synthesis results make an earlier implementation stale, as in Vivado.
        if synthJustRan, !outcome.completed.contains(.implementation), runs[.implementation]?.status == .complete {
            runs[.implementation]?.outOfDate = true
        }
        // write_bitstream is the last step of impl_1, so a bitstream means impl_1 is complete again.
        if outcome.completed.contains(.bitstream) {
            bitstreamReady = true
            if runs[.implementation]?.status == .running { runs[.implementation]?.status = .complete }
        }

        for file in outcome.reports {
            let entry = ReportEntry(run: file.run, fileName: file.name, text: file.text)
            reports.removeAll { $0.id == entry.id }
            reports.append(entry)
        }
        reports.sort { ($0.run == .synthesis ? 0 : 1, $0.fileName) < ($1.run == .synthesis ? 0 : 1, $1.fileName) }

        timing = reports.first { $0.run == .implementation && $0.fileName == BuildSummary.timingReport }
            .flatMap { try? TimingSummary.parse($0.text) }
        let utilizationText = reports.first { $0.run == .implementation && $0.fileName == BuildSummary.utilizationReport }
            ?? reports.first { $0.run == .synthesis }
        utilization = utilizationText.flatMap { try? UtilizationSummary.parse($0.text) }
    }

    private func ingest(_ chunk: String, into run: RunKind) {
        var buffer = buffers[run] ?? LineBuffer()
        let lines = buffer.append(chunk)
        buffers[run] = buffer
        logs[run, default: []].append(contentsOf: lines.map { ConsoleLine(text: $0, kind: ConsoleLine.classify($0)) })
    }

    func messages(for run: RunKind) -> [ConsoleLine] {
        logs[run, default: []].filter { $0.kind == .info || $0.kind == .warning || $0.kind == .error }
    }

    func count(_ kind: ConsoleLine.Kind) -> Int {
        [RunKind.synthesis, .implementation].reduce(0) { $0 + messages(for: $1).filter { $0.kind == kind }.count }
    }

    // MARK: Tcl console

    func submitTcl(_ text: String) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        tclLines.append(ConsoleLine(text: command, kind: .command))
        let project = project
        Task { [weak self] in
            guard let backend = self?.backend else { return }
            await backend.runTcl(command, project: project) { chunk in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.ingestTcl(chunk) } }
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
            if let self {
                let rest = self.tclBuffer.flush()
                self.tclLines.append(contentsOf: rest.map { ConsoleLine(text: $0, kind: ConsoleLine.classify($0)) })
            }
        }
    }

    private func ingestTcl(_ chunk: String) {
        tclLines.append(contentsOf: tclBuffer.append(chunk).map { ConsoleLine(text: $0, kind: ConsoleLine.classify($0)) })
    }

    /// GUI actions print the Tcl command they stand for, as Vivado does, so the console teaches the scripting.
    private func echoTcl(_ command: String) {
        tclLines.append(ConsoleLine(text: command, kind: .command))
    }

    func clearTcl() { tclLines = [] }

    // MARK: Workspace tabs

    func open(_ tab: WorkspaceTab) {
        if !openTabs.contains(tab) { openTabs.append(tab) }
        selectedTab = tab
    }

    func close(_ tab: WorkspaceTab) {
        guard tab.isCloseable, let index = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: index)
        if selectedTab == tab { selectedTab = openTabs[max(0, index - 1)] }
    }

    func openFile(_ path: String) { open(.file(path)) }

    func openReport(_ id: String) { open(.report(id)) }

    func report(_ id: String) -> ReportEntry? { reports.first { $0.id == id } }

    func title(of tab: WorkspaceTab) -> String {
        switch tab {
        case .summary: "Project Summary"
        case .file(let path): (path as NSString).lastPathComponent
        case .report(let id): report(id).map { "\($0.title) – \($0.run.runName)" } ?? "Report"
        }
    }

    func symbol(of tab: WorkspaceTab) -> String {
        switch tab {
        case .summary: "square.grid.2x2"
        case .file(let path): (path as NSString).pathExtension.lowercased() == "xdc" ? "pin" : "doc.text"
        case .report: "doc.plaintext"
        }
    }

    // MARK: Recent projects

    private static let recentsKey = "FPGABridge.recentProjects"

    private func loadRecents() -> [URL] {
        guard persist else { return [] }
        return (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Project.fileName).path) }
    }

    private func addRecent(_ url: URL) {
        recentProjects.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentProjects.insert(url, at: 0)
        recentProjects = Array(recentProjects.prefix(8))
        if persist { UserDefaults.standard.set(recentProjects.map(\.path), forKey: Self.recentsKey) }
    }
}
