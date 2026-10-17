import FPGABridgeCore
import Foundation

enum LintState: Equatable {
    case idle
    case running
    case done(LintReport)
    case failed(LintFailure)
}

extension AppModel {
    var isLinting: Bool { lint == .running }

    /// Run Linter: Vivado's RTL linter on the build machine, results in the Linter window.
    func runLinter() {
        guard let project, let directory = projectURL, !isRunning, !isLinting else { return }
        lint = .running
        open(.linter)
        echoTcl("synth_design -lint -top \(project.top) -part \(project.part)")
        let backend = backend
        Task {
            let result = await backend.lint(project: project, directory: directory) { _ in }
            guard self.projectURL == directory else { return }
            switch result {
            case .success(let report): lint = .done(report)
            case .failure(let failure): lint = .failed(failure)
            }
        }
    }

    /// The project file a linter message names (Vivado gives only the file's name), if there is exactly one.
    func projectFile(named name: String) -> String? {
        let matches = allSourcePaths.filter { ($0 as NSString).lastPathComponent == name }
        return matches.count == 1 ? matches[0] : matches.first
    }

    /// Every file in the Sources window.
    var allSourcePaths: [String] {
        func walk(_ nodes: [SourceNode]) -> [String] { nodes.flatMap { ($0.path.map { [$0] } ?? []) + walk($0.children ?? []) } }
        return walk(sourceTree)
    }
}
