import PorpoiseHelperKit
import Testing

struct HostileHelperPathTests {
    @Test func combiningMarksDontHideTrashSeparators() {
        let acute = "\u{301}"
        // The root helper's "a volume's Trash" isn't fooled by a folder named with a combining mark.
        #expect(
            !PorpoiseHelperInfo.isInUsersTrash(
                path: "/Volumes/X/\(acute)/.Trashes/501/f", resolvedParent: "/Volumes/X/\(acute)/.Trashes/501",
                uid: 501, resolvedHomeTrash: "/Users/me/.Trash"))

    }
}
