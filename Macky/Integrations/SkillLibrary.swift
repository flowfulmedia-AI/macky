import Foundation
import MackyCore

/// The user's Claude skills, read from a folder (default ~/Documents/Macky/Skills).
/// Each skill is a folder with SKILL.md, a single .md file, or a .zip / .skill archive as downloaded
/// from Claude (unpacked automatically). The folder is re-read whenever its contents change.
@MainActor
final class SkillLibrary: ObservableObject {
    @Published private(set) var skills: [SkillDefinition] = []
    @Published private(set) var lastError: String?

    private let settings: AppSettings
    private var lastScannedModificationDate: Date?
    private var lastScannedPath = ""

    static var defaultFolderPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Macky/Skills").path
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    var folderURL: URL {
        let path = settings.skillsFolderPath.isEmpty ? Self.defaultFolderPath : (settings.skillsFolderPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Cheap when nothing changed: only the folder's modification date is read.
    func reloadIfChanged() {
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: folderURL.path)[.modificationDate]) as? Date
        guard folderURL.path != lastScannedPath || modificationDate != lastScannedModificationDate else { return }
        reload()
    }

    func reload() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        lastScannedPath = folderURL.path
        unpackArchives()
        lastScannedModificationDate = (try? fileManager.attributesOfItem(atPath: folderURL.path)[.modificationDate]) as? Date

        var foundSkills: [SkillDefinition] = []
        let entries = (try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if let skillFileURL = Self.skillFile(in: entry, depth: 2),
                   let markdown = try? String(contentsOf: skillFileURL, encoding: .utf8),
                   let skill = SkillParser.parse(markdown: markdown, fallbackName: entry.lastPathComponent, sourcePath: skillFileURL.path) {
                    foundSkills.append(skill)
                }
            } else if entry.pathExtension.lowercased() == "md",
                      let markdown = try? String(contentsOf: entry, encoding: .utf8),
                      let skill = SkillParser.parse(markdown: markdown, fallbackName: entry.deletingPathExtension().lastPathComponent, sourcePath: entry.path) {
                foundSkills.append(skill)
            }
        }
        skills = foundSkills
        lastError = nil
    }

    func skill(named name: String) -> SkillDefinition? {
        reloadIfChanged()
        return SkillCatalog.find(name, in: skills)
    }

    /// Finds SKILL.md (any capitalization) in a folder or, for archives that wrap everything in one folder, one level down.
    private static func skillFile(in folderURL: URL, depth: Int) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        if let skillFile = entries.first(where: { $0.lastPathComponent.lowercased() == "skill.md" }) { return skillFile }
        guard depth > 1 else { return nil }
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let skillFile = skillFile(in: entry, depth: depth - 1) { return skillFile }
        }
        return nil
    }

    /// Skills downloaded from Claude come as .zip or .skill archives; they are unpacked next to themselves once.
    private func unpackArchives() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for archiveURL in entries where ["zip", "skill"].contains(archiveURL.pathExtension.lowercased()) {
            let destinationURL = archiveURL.deletingPathExtension()
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                lastError = "Nu am putut dezarhiva \(archiveURL.lastPathComponent)."
            }
        }
    }
}
