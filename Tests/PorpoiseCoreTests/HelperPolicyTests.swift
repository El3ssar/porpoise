import Foundation
import Testing
@testable import PorpoiseCore

/// The root helper hands items over only inside the asking user's own Trash.
@Suite struct HelperPolicyTests {
    let trash = "/Users/me/.Trash"

    @Test func itemsInTheHomeTrash() {
        #expect(PorpoiseHelperInfo.isInUsersTrash(path: "/Users/me/.Trash/Game.app", resolvedParent: trash, uid: 501, resolvedHomeTrash: trash))
    }

    @Test func itemsInAVolumesTrashForThatUser() {
        #expect(PorpoiseHelperInfo.isInUsersTrash(path: "/Volumes/Disk/.Trashes/501/x", resolvedParent: "/Volumes/Disk/.Trashes/501", uid: 501, resolvedHomeTrash: trash))
        #expect(!PorpoiseHelperInfo.isInUsersTrash(path: "/Volumes/Disk/.Trashes/502/x", resolvedParent: "/Volumes/Disk/.Trashes/502", uid: 501, resolvedHomeTrash: trash))
    }

    @Test func nothingElse() {
        for (path, parent) in [("/etc/sudoers", "/etc"), ("/Users/me/.Trash/a/b", "/Users/me/.Trash/a"), ("/Users/other/.Trash/x", "/Users/other/.Trash"),
                               ("/Users/me/.Trash/..", trash), ("/Volumes/Disk/.Trashes/501/../x", "/Volumes/Disk/.Trashes"),
                               ("/Volumes/../.Trashes/501/x", "/Volumes/../.Trashes/501"), ("/Library/.Trashes/501/x", "/Library/.Trashes/501")] {
            #expect(!PorpoiseHelperInfo.isInUsersTrash(path: path, resolvedParent: parent, uid: 501, resolvedHomeTrash: trash), "\(path)")
        }
    }
}
