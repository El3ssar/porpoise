import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Exercise the app's real list view without listing a server, device, or account.
@MainActor @Suite(.isolatedSettings) struct LocationViewSettingsTests {
    enum Location: String, CaseIterable {
        case local, drive, driveShared, dropbox, dropboxShared, network, sftp, smb, mtp, android, archive, recent, tags, smart, applications
        var url: URL {
            switch self {
            case .local: return URL(fileURLWithPath: "/tmp/view-settings/local")
            case .drive: return URL(string: "gdrive://00000000-0000-0000-0000-000000000001/my-drive/folder/")!
            case .driveShared: return URL(string: "gdrive://00000000-0000-0000-0000-000000000001/shared-with-me/")!
            case .dropbox:
                return DropboxLocation(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, itemID: "id:folder", namespaceID: "home")
                    .url
            case .dropboxShared:
                return DropboxLocation(
                    accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, itemID: "collection:shared", namespaceID: "home"
                ).url
            case .network: return URL(string: "network:/")!
            case .sftp: return URL(string: "sftp://fixture@example.invalid/folder/")!
            case .smb: return URL(string: "smb://fixture.invalid/share/folder/")!
            case .mtp: return URL(string: "mtp://fixture-device/storage/folder/")!
            case .android: return URL(string: "adb://fixture-device/sdcard/folder/")!
            // ArchiveBrowser presents extracted archive contents as local cache folders.
            case .archive: return URL(fileURLWithPath: "/tmp/view-settings/archives/digest-version/archive.zip/folder")
            case .recent: return URL(string: "recent:/locations")!
            case .tags: return URL(string: "tags:/fixture")!
            case .smart: return URL(string: "smart:/tmp/fixture.savedSearch")!
            case .applications: return AppLibrary.location
            }
        }
    }

    @Test(arguments: Location.allCases) func everyLocationUsesCommonAndRememberedSettings(_ location: Location) throws {
        _ = NSApplication.shared
        let store = Settings.store
        // Switch policy directly and reload explicitly, independently of settings-notification delivery.
        store.set(false, forKey: "dynamicView")
        let other = URL(fileURLWithPath: "/tmp/view-settings/unrelated")
        for mode in ViewMode.allCases {
            store.set(false, forKey: "perFolder")
            var common = ViewProperties(); common.mode = mode; common.sortRole = .size; common.previews = false
            common.setIconSize(73, for: mode)
            ViewStyleStore().save(common, for: other)
            let model = DirectoryModel(location: location.url)
            let list = ItemListView(model: model)
            #expect(list.mode == mode && model.props == common)
            model.reloadProps()
            #expect(model.props == common)
            model.props.showHidden = true
            model.saveProps()
            #expect(DirectoryModel(location: other).props.showHidden)

            store.set(true, forKey: "perFolder")
            model.props.mode = mode == .compact ? .details : .compact
            model.props.sortRole = .modificationTime
            model.props.setRoles([.path, .owner], for: .details)
            model.saveProps()
            let remembered = model.props
            #expect(DirectoryModel(location: location.url).props == remembered)
            #expect(DirectoryModel(location: other).props.mode == mode)
            model.reloadProps()
            #expect(list.mode == remembered.mode && model.props == remembered)
            // Common mode must ignore a location's saved style; returning to per-folder mode restores it.
            store.set(false, forKey: "perFolder"); model.reloadProps()
            #expect(list.mode == mode)
            store.set(true, forKey: "perFolder"); model.reloadProps()
            #expect(model.props == remembered)
        }
    }
}
