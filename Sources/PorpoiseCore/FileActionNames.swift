/// Pure name policy shared by templates, rename planning and local operations.
public enum FileActions {
    /// A single path component: not empty, no "/", not "." or "..".
    public static func isValidName(_ name: String) -> Bool { FileName.isValid(name, for: .component) }
}
