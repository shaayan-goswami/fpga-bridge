import AppKit
import FPGABridgeCore
import SwiftUI

/// Everything the window shows. Runs follow Vivado's rules: Run Implementation runs synthesis first if it is
/// missing or out-of-date, Generate Bitstream runs whatever it needs, and changing sources or settings marks
/// finished runs out-of-date.
@MainActor
final class AppModel: ObservableObject {
    let backend: Backend
    let hardware: HardwareManager
    let simulation: SimulationManager
    let waveform = WaveformModel()
    private let ipBackend: IPBackend
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
    @Published var unsavedPrompt: UnsavedPrompt?

    // Text being edited, by project-relative path. A file is in here only while it differs from what is on disk.
    @Published private(set) var drafts: [String: String] = [:]

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
    /// What the last build wrote about the design at each stage.
    @Published private(set) var designs: [DesignStage: DesignSnapshot] = [:]
    /// A design view to open once the build that produces it has finished.
    private var pendingDesign: DesignStage?

    // Opened designs (see DesignSelection.swift)
    /// The design the Netlist and Properties windows show: the last one opened, as in Vivado.
    @Published var activeDesign: DesignStage?
    /// The selected cells, nets, ports and pins, shared by every design window. The last is the one Properties shows.
    @Published var designSelection: [DesignObjectRef] = []
    /// Which window the left pane shows: Sources, or the open design's Netlist.
    @Published var sidePane: SidePane = .sources
    /// Whether Properties shows the selected design object (true) or the selected source file.
    @Published var propertiesShowsDesign = false
    /// A line to show in an open editor (Go To Source), by file.
    @Published var editorReveal: [String: EditorReveal] = [:]
    /// What each design's Schematic window shows, and the earlier views for its Previous button.
    @Published var schematicSpecs: [DesignStage: SchematicSpec] = [:]
    var schematicHistory: [DesignStage: [SchematicSpec]] = [:]
    var schematicFuture: [DesignStage: [SchematicSpec]] = [:]
    /// Run Linter's state and findings.
    @Published var lint: LintState = .idle
    @Published private(set) var timing: TimingSummary?
    @Published private(set) var utilization: UtilizationSummary?
    @Published private(set) var lastMessage = "Ready"
    @Published private(set) var lastOutcome: RunStatus?
    @Published private(set) var connection: ConnectionState = .checking

    private var runTask: Task<Void, Never>?
    /// Bumped whenever a run starts or is abandoned. A task from an earlier generation may still be finishing after
    /// it was cancelled; it must not touch the state of the run that replaced it.
    private var runGeneration = 0
    private var buffers: [RunKind: LineBuffer] = [:]
    private var tclBuffer = LineBuffer()
    private var fileCache: [String: String] = [:]

    /// `hardware` defaults to a pretend board so tests never touch a real one.
    init(backend: Backend, hardware: HardwareBackend = DemoHardware(speed: 0),
         simulation: SimulationBackend = DemoSimulation(speed: 0), ips: IPBackend = DemoIPBackend(speed: 0), persist: Bool) {
        self.backend = backend
        self.ipBackend = ips
        self.hardware = HardwareManager(backend: hardware)
        self.simulation = SimulationManager(backend: simulation)
        self.persist = persist
        recentProjects = loadRecents()
        tclLines = [ConsoleLine(text: "# FPGA Bridge Tcl console. Commands run in Vivado on the build machine.", kind: .output)]
        self.hardware.console = { [weak self] text, kind in self?.tclLines.append(ConsoleLine(text: text, kind: kind)) }
        self.simulation.console = { [weak self] text, kind in self?.tclLines.append(ConsoleLine(text: text, kind: kind)) }
    }

    static func make() -> AppModel {
        if !DebugHooks.forceDemo, let config = try? BridgeConfig.load() {
            return AppModel(backend: LiveBackend(config: config), hardware: LiveHardware(), simulation: LiveSimulation(),
                            ips: LiveIPBackend(config: config), persist: DebugHooks.persistRecents)
        }
        return AppModel(backend: DemoBackend(speed: DebugHooks.demoSpeed), hardware: DemoHardware(speed: DebugHooks.demoSpeed),
                        simulation: DemoSimulation(speed: DebugHooks.demoSpeed), ips: DemoIPBackend(speed: DebugHooks.demoSpeed),
                        persist: DebugHooks.persistRecents)
    }

    func start() async {
        connection = .checking
        connection = await backend.checkConnection()
        await applyLaunchScenario()
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
        afterResolvingUnsaved { self.loadProject(at: url) }
    }

    private func loadProject(at url: URL) {
        let directory = url.pathExtension == "json" ? url.deletingLastPathComponent() : url
        do {
            let loaded = try Project.load(from: directory)
            cancelRun()
            simulation.reset()
            waveform.clear()
            drafts = [:]
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
            restorePreviousBuild(in: directory)
        } catch {
            errorMessage = "Couldn't open the project: \(error.userMessage)"
        }
    }

    func closeProject() {
        afterResolvingUnsaved {
            self.cancelRun()
            self.simulation.reset()
            self.waveform.clear()
            self.drafts = [:]
            self.echoTcl("close_project")
            self.discardProject()
        }
    }

    private func discardProject() {
        clearRunState(message: "Ready")
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
        let base = DebugHooks.examplesDirectory
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
            errorMessage = "Couldn't create the example project: \(error.userMessage)"
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
            errorMessage = "\(error.userMessage)"
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
            errorMessage = "\(error.userMessage)"
        }
    }

    /// Project Settings: General, and the Elaboration, Simulation, Synthesis, Implementation and Bitstream pages.
    func applySettings(top: String, part: String, board: String?, language: String, vivadoVersion: String?,
                       settings: ProjectSettings? = nil, simulationTop: String? = nil) {
        guard var updated = project, let projectURL else { return }
        let original = updated
        updated.top = top
        updated.part = part
        updated.board = board
        updated.targetLanguage = language
        updated.vivadoVersion = vivadoVersion
        if let settings {
            updated.settings = settings.isDefault ? nil : settings
            updated.simulationTop = simulationTop
        }
        do {
            try updated.validate()
            try updated.save(to: projectURL)
            if updated.part != project?.part { echoTcl("set_property part \(part) [current_project]") }
            if updated.top != project?.top { echoTcl("set_property top \(top) [current_fileset]") }
            if settings != nil { echoSettingsChanges(from: original, to: updated) }
            reloadProjectAfterChange(outOfDate: Self.runsAffected(by: original, updated))
        } catch {
            errorMessage = "\(error.userMessage)"
        }
    }

    /// Tells the console what the next run will do differently: the real Tcl lines that changed.
    private func echoSettingsChanges(from old: Project, to new: Project) {
        func lines(_ project: Project) -> [String] {
            project.buildScript(sources: [], constraints: []).split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("#") && !$0.hasPrefix("file mkdir") && !$0.hasPrefix("report_") }
        }
        let before = Set(lines(old))
        let changed = lines(new).filter { !before.contains($0) }
        if !changed.isEmpty {
            tclLines.append(ConsoleLine(text: "INFO: the next run will use: " + changed.joined(separator: "; "), kind: .info))
        }
        if old.settings?.simulation != new.settings?.simulation || old.simulationTop != new.simulationTop {
            tclLines.append(ConsoleLine(text: "INFO: simulation settings changed; the next simulation will use them", kind: .info))
        }
    }

    /// Which finished runs a change to the project makes out-of-date. Simulation settings touch no run, a bitstream
    /// setting only the implementation run (the bitstream is its last step), and anything that changes the design
    /// itself (top, part, language and synthesis options) both.
    static func runsAffected(by old: Project, _ new: Project) -> [RunKind] {
        let both: [RunKind] = [.synthesis, .implementation]
        if old.top != new.top || old.part != new.part { return both }
        let a = old.settings ?? ProjectSettings(), b = new.settings ?? ProjectSettings()
        if a.language != b.language || a.synthesis != b.synthesis { return both }
        if a.implementation != b.implementation || a.bitstream != b.bitstream { return [.implementation] }
        return []
    }

    private func reloadProjectAfterChange(outOfDate kinds: [RunKind] = [.synthesis, .implementation]) {
        guard let projectURL else { return }
        do {
            project = try Project.load(from: projectURL)
        } catch {
            errorMessage = "Couldn't reload the project: \(error.userMessage)"
            return
        }
        fileCache = [:]
        rebuildSourceTree()
        markOutOfDate(kinds)
    }

    private func markOutOfDate(_ kinds: [RunKind] = [.synthesis, .implementation]) {
        for kind in kinds where runs[kind]?.status == .complete {
            runs[kind]?.outOfDate = true
        }
    }

    private func rebuildSourceTree() {
        guard let project, let projectURL else { sourceTree = []; return }
        do {
            sourceTree = SourceTreeBuilder.build(
                top: project.top,
                design: try project.resolveSources(in: projectURL),
                constraints: try project.resolveConstraints(in: projectURL),
                simulation: try project.resolveSimulationSources(in: projectURL),
                read: contents(of:))
        } catch {
            // An empty tree with no explanation looks like an empty project.
            sourceTree = []
            errorMessage = "Couldn't read the project's source files: \(error.userMessage)"
        }
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

    // MARK: Editing

    var hasUnsavedChanges: Bool { !drafts.isEmpty }

    func isDirty(_ path: String) -> Bool { drafts[path] != nil }

    /// What the editor shows: the unsaved text if there is any, otherwise the file.
    func editedText(for path: String) -> String { drafts[path] ?? contents(of: path) }

    func updateDraft(_ text: String, for path: String) {
        if text == contents(of: path) {
            if drafts[path] != nil { drafts[path] = nil }
        } else if drafts[path] != text {
            drafts[path] = text
        }
    }

    /// Writes an edited file back into the project. Like Vivado, changing a design or constraint source makes
    /// finished runs out-of-date; a testbench doesn't affect synthesis. Returns false if the write failed.
    @discardableResult
    func saveFile(_ path: String) -> Bool {
        guard let projectURL, let text = drafts[path] else { return true }
        do {
            try text.write(to: projectURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't save \((path as NSString).lastPathComponent): \(error.localizedDescription)"
            return false
        }
        fileCache[path] = text
        drafts[path] = nil
        if !path.contains("/\(SourceSet.simulation.directoryName)/") { markOutOfDate() }
        rebuildSourceTree()
        lastMessage = "Saved \((path as NSString).lastPathComponent)"
        return true
    }

    func saveCurrentFile() {
        if case .file(let path) = selectedTab { saveFile(path) }
    }

    @discardableResult
    func saveAll() -> Bool {
        drafts.keys.sorted().allSatisfy { saveFile($0) }
    }

    /// Runs `action` now, or after the user has dealt with unsaved edits.
    func afterResolvingUnsaved(_ action: @escaping () -> Void) {
        if drafts.isEmpty {
            action()
        } else {
            unsavedPrompt = UnsavedPrompt(files: drafts.keys.sorted(), proceed: action)
        }
    }

    func resolveUnsaved(_ choice: UnsavedChoice) {
        guard let prompt = unsavedPrompt else { return }
        unsavedPrompt = nil
        switch choice {
        case .save:
            if prompt.files.allSatisfy({ saveFile($0) }) { prompt.proceed() }
        case .discard:
            prompt.files.forEach { drafts[$0] = nil }
            prompt.proceed()
        case .cancel:
            break
        }
    }

    // MARK: Flow Navigator

    func perform(_ item: FlowItem) {
        guard item.isAvailable, hasProject else { return }
        switch item {
        case .settings: showSettings = true
        case .addSources: showAddSources = true
        case .openHardwareManager: open(.hardware)
        case .ipCatalog: openIPCatalog()
        case .openElaboratedDesign, .openSynthesizedDesign, .openImplementedDesign:
            if let stage = item.designStage { openDesign(stage) }
        case .languageTemplates: open(.templates)
        case .runSimulation: runSimulation()
        case .runLinter: runLinter()
        default: if let kind = item.runKind { run(kind) }
        }
    }

    // MARK: IP Catalog

    enum IPLoad: Equatable {
        case idle
        case loading
        case failed(String)
    }

    @Published private(set) var ipCatalog: IPCatalog?
    @Published private(set) var ipLoad = IPLoad.idle
    /// Instantiation templates already fetched, by instance name and configuration, so reopening one is instant.
    @Published private(set) var ipTemplates: [String: IPScriptOutput] = [:]

    /// Shows the IP Catalog, loading it from the build machine the first time.
    func openIPCatalog() {
        open(.ipCatalog)
        if ipCatalog == nil, ipLoad != .loading { loadIPCatalog() }
    }

    func loadIPCatalog(refresh: Bool = false) {
        guard let part = project?.part, ipLoad != .loading else { return }
        ipLoad = .loading
        Task {
            do {
                ipCatalog = try await ipBackend.catalog(part: part, refresh: refresh)
                ipLoad = .idle
            } catch {
                ipLoad = .failed(error.userMessage)
            }
        }
    }

    /// The settings of an IP with their defaults, for the Customize IP sheet.
    func ipProperties(of definition: IPDefinition) async throws -> [IPProperty] {
        guard let part = project?.part else { return [] }
        return try await ipBackend.properties(of: definition, part: part)
    }

    private func templateKey(_ ip: ProjectIP) -> String {
        ip.vlnv + "|" + ip.name + "|" + ip.config.keys.sorted().map { "\($0)=\(ip.config[$0] ?? "")" }.joined(separator: ",")
    }

    /// The instantiation templates for an IP as configured. Throws what Vivado said if it refuses the settings.
    func ipTemplate(for ip: ProjectIP) async throws -> IPScriptOutput {
        let key = templateKey(ip)
        if let cached = ipTemplates[key] { return cached }
        guard let part = project?.part else { return IPScriptOutput() }
        let result = try await ipBackend.template(for: ip, part: part)
        ipTemplates[key] = result
        return result
    }

    /// Adds an IP to the project once Vivado has accepted its settings, then writes the project file.
    func addIP(_ ip: ProjectIP) async throws {
        guard var updated = project, let projectURL else { return }
        try ip.validate()
        guard !(updated.ips ?? []).contains(where: { $0.name == ip.name }) else {
            throw ProjectIP.IPError.invalid("the project already has an IP called '\(ip.name)'")
        }
        _ = try await ipTemplate(for: ip)              // Vivado checks the settings; nothing is saved if it refuses
        updated.ips = (updated.ips ?? []) + [ip]
        try updated.validate()
        try updated.save(to: projectURL)
        echoTcl("create_ip -name \(ip.vlnvParts?[2] ?? ip.vlnv) -vendor \(ip.vlnvParts?[0] ?? "") -library \(ip.vlnvParts?[1] ?? "") -version \(ip.vlnvParts?[3] ?? "") -module_name \(ip.name)")
        reloadProjectAfterChange(outOfDate: [.synthesis, .implementation])
    }

    func removeIP(named name: String) {
        guard var updated = project, let projectURL, (updated.ips ?? []).contains(where: { $0.name == name }) else { return }
        updated.ips = (updated.ips ?? []).filter { $0.name != name }
        if updated.ips?.isEmpty == true { updated.ips = nil }
        do {
            try updated.save(to: projectURL)
            echoTcl("remove_files [get_files \(name).xci]")
            reloadProjectAfterChange(outOfDate: [.synthesis, .implementation])
        } catch {
            errorMessage = "\(error.userMessage)"
        }
    }

    // MARK: Design views

    /// Shows what the last build left in `build/` (reports and design data), so reopening a project doesn't lose them.
    /// Run states are left alone: the results may be older than the sources, and only a run can say they are current.
    private func restorePreviousBuild(in directory: URL) {
        guard !backend.isDemo else { return }
        let out = directory.appendingPathComponent(Remote.localOutputDir)
        Task { [weak self] in
            let (files, designs) = await Task.detached { () -> ([ReportFile], [DesignStage: DesignSnapshot]) in
                var found: [DesignStage: DesignSnapshot] = [:]
                for stage in DesignStage.allCases {
                    if let snapshot = try? DesignSnapshot.load(stage: stage, from: out) { found[stage] = snapshot }
                }
                return (LiveBackend.reports(in: out), found)
            }.value
            guard let self, self.projectURL == directory, !files.isEmpty || !designs.isEmpty else { return }
            self.apply(RunOutcome(completed: [], reports: files, designs: designs))
        }
    }

    /// Opens the Elaborated, Synthesized or Implemented Design. If no build has produced it yet, runs one, and opens the
    /// view when it finishes (Vivado runs synthesis when you open the synthesized design, too).
    func openDesign(_ stage: DesignStage) {
        if designs[stage] != nil { showDesign(stage); return }
        guard !isRunning else { return }
        run(stage == .impl ? .implementation : .synthesis)
        pendingDesign = stage
    }

    // MARK: Simulation

    /// How to show a waveform. Replaced in tests so they never launch a program.
    var findWaveformViewer: () -> WaveformViewer? = { WaveformViewer.locate() }
    var launchWaveformViewer: (WaveformViewer, URL) throws -> Void = { try $0.open($1) }
    var hasDefaultApp: (URL) -> Bool = { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil }
    var openInDefaultApp: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Opens a waveform in Surfer or GTKWave, or whatever the Mac has for `.vcd`. With none of those, says how to
    /// install one: showing the file in the Finder would only lead to "no application set to open the document".
    func openWaveform(_ url: URL) {
        if let viewer = findWaveformViewer() {
            do { try launchWaveformViewer(viewer, url) } catch { errorMessage = "Couldn't open \(viewer.name): \(error.userMessage)" }
        } else if hasDefaultApp(url) {
            openInDefaultApp(url)
        } else {
            errorMessage = WaveformViewerError.notInstalled.userMessage
        }
    }

    /// Runs the testbench and shows the Simulation tab.
    func runSimulation() {
        guard let project, let projectURL, !simulation.isRunning else { return }
        consoleTab = .tclConsole
        open(.simulation)
        Task {
            let outcome = await simulation.run(project: project, directory: projectURL)
            // Like Vivado, show the waveform when a simulation finishes.
            if outcome?.result == .finished, let file = outcome?.waveform { await showWaveform(file) }
        }
    }

    /// Loads a waveform file into the Waveform tab and shows it.
    func showWaveform(_ url: URL) async {
        open(.waveform)
        await waveform.load(url)
    }

    // MARK: Hardware

    /// The board the project was created for, which tells the loader what cable to use.
    var projectBoard: Board? { project?.board.flatMap { BoardCatalog.lookup($0) } }

    /// `build/<top>.bit`, where `fpga-bridge build` puts the bitstream.
    var defaultBitstreamPath: String {
        guard let project, let projectURL else { return "" }
        return projectURL.appendingPathComponent(Remote.localOutputDir).appendingPathComponent("\(project.top).bit").path
    }

    func autoConnectHardware() {
        consoleTab = .tclConsole
        let board = projectBoard
        Task { await hardware.openTarget(board: board) }
    }

    func programHardware(bitstream: String, kind: ProgramKind) {
        consoleTab = .tclConsole
        consoleVisible = true
        let board = projectBoard
        Task { await hardware.program(bitstream: bitstream, board: board, kind: kind) }
    }

    /// Vivado's behavior: each step runs what it depends on if that is missing or out-of-date.
    func run(_ target: RunKind) {
        pendingDesign = nil     // a build the user starts by hand doesn't open a design view when it ends
        execute(RunPlanner.steps(for: target,
                                 synthesisUpToDate: runs[.synthesis]?.isUpToDate == true,
                                 implementationUpToDate: runs[.implementation]?.isUpToDate == true))
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
        designs = [:]
        pendingDesign = nil
        designSelection = []
        propertiesShowsDesign = false
        lint = .idle
        ipCatalog = nil
        ipTemplates = [:]
        ipLoad = .idle
        timing = nil
        utilization = nil
        lastOutcome = nil
        lastMessage = message
    }

    private func cancelRun() {
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        isRunning = false
        activeStep = nil
        stepStarted = nil
    }

    private func execute(_ plan: [RunKind]) {
        guard !isRunning, let project, let projectURL, !plan.isEmpty else { return }
        isRunning = true
        consoleVisible = true
        runGeneration += 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            guard let self else { return }
            for (index, step) in plan.enumerated() {
                guard !Task.isCancelled, runGeneration == generation else { return }
                // A live run completes every step at once, so later steps may already be done.
                if index > 0, isDone(step) { continue }
                let succeeded = await performStep(step, project: project, directory: projectURL, generation: generation)
                if !succeeded { break }
            }
            guard runGeneration == generation else { return }
            activeStep = nil
            stepStarted = nil
            isRunning = false
            runTask = nil
        }
    }

    private func isDone(_ step: RunKind) -> Bool {
        step == .bitstream ? bitstreamReady && runs[.implementation]?.isUpToDate == true : runs[step]?.isUpToDate == true
    }

    /// Returns false if the step failed, was cancelled, or belongs to a run that has since been abandoned.
    private func performStep(_ step: RunKind, project: Project, directory: URL, generation: Int) async -> Bool {
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

        // Captured strongly on purpose: the call is short-lived, and the run task keeps the model alive anyway.
        let model = self
        let outcome = await backend.run(step, project: project, directory: directory) { chunk in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Output from a run that was abandoned must not land in the log of its replacement.
                    guard model.runGeneration == generation else { return }
                    model.ingest(chunk, into: run)
                }
            }
        }
        // Chunks are delivered through the main queue; let the ones already queued land before finishing.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
        guard runGeneration == generation else { return false }
        if var buffer = buffers[run] {
            logs[run, default: []].append(contentsOf: buffer.flush().map { ConsoleLine(text: $0, kind: ConsoleLine.classify($0)) })
            buffers[run] = buffer
        }
        runs[run]?.elapsed += Date().timeIntervalSince(started)

        if outcome.cancelled {
            // Cancelling write_bitstream leaves impl_1 as it was: complete, with no bitstream.
            runs[run]?.status = step == .bitstream ? .complete : .cancelled
            lastOutcome = .cancelled
            lastMessage = step == .bitstream ? "write_bitstream cancelled" : "\(step.runName) cancelled"
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

        for (stage, snapshot) in outcome.designs { designs[stage] = snapshot }
        if let stage = pendingDesign, designs[stage] != nil {
            pendingDesign = nil
            showDesign(stage)
        }

        timing = reports.first { $0.run == .implementation && $0.fileName == BuildSummary.timingReport }
            .flatMap { try? TimingSummary.parse($0.text) }
        let utilizationText = reports.first { $0.run == .implementation && $0.fileName == BuildSummary.utilizationReport }
            ?? reports.first { $0.run == .synthesis && $0.fileName == "synth_utilization.rpt" }
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
    func echoTcl(_ command: String) {
        tclLines.append(ConsoleLine(text: command, kind: .command))
    }

    func clearTcl() { tclLines = [] }

    // MARK: Workspace tabs

    func open(_ tab: WorkspaceTab) {
        if !openTabs.contains(tab) { openTabs.append(tab) }
        selectedTab = tab
        if case .file(let path) = tab { lastFile = path }
        if case .design(let stage) = tab { designOpened(stage) }
        if case .schematic(let stage) = tab { designOpened(stage) }
    }

    // MARK: Language templates

    /// The file a template goes into: the one most recently open in the editor, as in Vivado.
    @Published private(set) var lastFile: String?
    /// The template chosen in the Language Templates tab, kept while you switch to a file and back.
    @Published var selectedTemplateID: String?
    /// Where the caret is in each open file, as a UTF-16 offset, reported by the editor.
    private var carets: [String: Int] = [:]

    func setCaret(_ offset: Int, in path: String) { carets[path] = offset }

    func caret(in path: String) -> Int? { carets[path] }

    /// Whether Insert Template has somewhere to put the text.
    var canInsertTemplate: Bool { lastFile.map { openTabs.contains(.file($0)) } ?? false }

    /// Inserts `text` at the caret of the last edited file (at the end if the caret isn't known), then shows that file.
    func insertTemplate(_ text: String) {
        guard let path = lastFile, openTabs.contains(.file(path)) else { return }
        let current = editedText(for: path) as NSString
        let at = min(carets[path] ?? current.length, current.length)
        // Start on a line of its own, so a template pasted mid-line doesn't join the code before it.
        let atLineStart = at == 0 || current.character(at: at - 1) == 10
        let piece = (atLineStart ? "" : "\n") + text
        updateDraft(current.replacingCharacters(in: NSRange(location: at, length: 0), with: piece), for: path)
        carets[path] = at + (piece as NSString).length
        open(.file(path))
    }

    /// Closes a tab, asking first if it holds unsaved edits.
    func requestClose(_ tab: WorkspaceTab) {
        if case .file(let path) = tab, isDirty(path) {
            unsavedPrompt = UnsavedPrompt(files: [path]) { [weak self] in self?.close(tab) }
        } else {
            close(tab)
        }
    }

    func close(_ tab: WorkspaceTab) {
        guard tab.isCloseable, let index = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: index)
        if selectedTab == tab { selectedTab = openTabs[max(0, index - 1)] }
        if case .design(let stage) = tab {
            // Closing a design closes its windows, as in Vivado.
            if let schematic = openTabs.firstIndex(of: .schematic(stage)) {
                openTabs.remove(at: schematic)
                if selectedTab == .schematic(stage) { selectedTab = openTabs.last ?? .summary }
            }
            designClosed(stage)
        }
    }

    func openFile(_ path: String) { open(.file(path)) }

    func openReport(_ id: String) { open(.report(id)) }

    func report(_ id: String) -> ReportEntry? { reports.first { $0.id == id } }

    func title(of tab: WorkspaceTab) -> String {
        switch tab {
        case .summary: "Project Summary"
        case .file(let path): (path as NSString).lastPathComponent
        case .report(let id): report(id).map { "\($0.title) – \($0.run.runName)" } ?? "Report"
        case .hardware: "Hardware Manager"
        case .design(let stage): stage.title
        case .schematic: "Schematic"
        case .linter: "Linter"
        case .ipCatalog: "IP Catalog"
        case .templates: "Language Templates"
        case .simulation: "Simulation"
        case .waveform: "Waveform"
        }
    }

    func symbol(of tab: WorkspaceTab) -> String {
        switch tab {
        case .summary: "square.grid.2x2"
        case .file(let path): (path as NSString).pathExtension.lowercased() == "xdc" ? "pin" : "doc.text"
        case .report: "doc.plaintext"
        case .hardware: "cable.connector.horizontal"
        case .design(let stage): stage == .rtl ? "square.stack.3d.up" : "rectangle.on.rectangle"
        case .schematic: "point.3.connected.trianglepath.dotted"
        case .linter: "checklist"
        case .ipCatalog: "puzzlepiece.extension"
        case .templates: "doc.text.magnifyingglass"
        case .simulation: "waveform.path.ecg"
        case .waveform: "waveform"
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
