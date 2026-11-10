import Foundation

/// Whether this process may open a file for reading. Only the open() matters: nothing is read, and a file in
/// Desktop, Documents, Downloads, iCloud Drive or a removable volume makes macOS ask for permission here the first time.
public enum FileReadAccess {
    /// True only when macOS (or the file's permissions) refuse. A missing file is not "denied": restoring reports that itself.
    public static func isDenied(path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK)
        if descriptor >= 0 { close(descriptor); return false }
        return errno == EPERM || errno == EACCES
    }
}
