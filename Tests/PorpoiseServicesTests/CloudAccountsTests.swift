import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Cloud accounts as the sidebar, the Connect sheet and Settings › Accounts see them, with the demo backend.
@MainActor @Suite(.isolatedSettings) struct CloudAccountsTests {
    let personal = CloudAccount(
        id: "a1", email: "daniel@gmail.com", displayName: "Daniel", quotaUsed: 4_000_000_000, quotaTotal: 15_000_000_000)
    let work = CloudAccount(id: "a2", email: "daniel@studio.com", displayName: "Daniel S", sharedDriveCount: 2)

    /// A fresh model on a demo backend that already has `accounts`.
    private func model(_ accounts: [CloudAccount] = []) -> (CloudAccounts, DemoCloudBackend) {
        let backend = DemoCloudBackend()
        for a in accounts {
            _ = backend.connect(.googleDrive, openBrowser: { _ in }, done: { _ in })
            backend.finishSignIn(a)
        }
        let m = CloudAccounts()
        m.backend = backend
        return (m, backend)
    }

    @Test func connectingWaitsForTheBrowserAndAddsTheSection() {
        let (m, backend) = model()
        var result: Result<CloudAccount, CloudConnectError>?
        _ = m.connect(.googleDrive, openBrowser: { _ in }, done: { result = $0 })
        #expect(backend.isSigningIn && result == nil)
        backend.finishSignIn(personal)
        #expect(result == .success(personal))
        #expect(PlacesModel.shared.accounts.map(\.id) == ["a1"])
        #expect(PlacesModel.shared.sections().map(\.0).contains(.account("a1")))
        #expect(PlacesModel.shared.accounts.first?.title == "Google Drive")
    }

    @Test func closingTheBrowserLeavesNothingBehind() {
        let (m, backend) = model()
        var result: Result<CloudAccount, CloudConnectError>?
        _ = m.connect(.googleDrive, openBrowser: { _ in }, done: { result = $0 })
        backend.finishSignIn(nil)
        #expect(result == .failure(.cancelled))
        #expect(m.accounts.isEmpty)
        // Cancel before the browser returns: the late answer is dropped.
        let cancel = m.connect(.googleDrive, openBrowser: { _ in }, done: { result = $0 })
        cancel()
        result = nil
        backend.finishSignIn(personal)
        #expect(result == nil && m.accounts.isEmpty)
    }

    @Test func theSameAccountTwiceIsShownNotAdded() {
        let (m, backend) = model([personal])
        var result: Result<CloudAccount, CloudConnectError>?
        _ = m.connect(.googleDrive, openBrowser: { _ in }, done: { result = $0 })
        backend.finishSignIn(CloudAccount(id: "other", email: "Daniel@Gmail.com", displayName: "Daniel"))
        #expect(result == .failure(.alreadyConnected(personal)))
        #expect(m.accounts.count == 1)
    }

    @Test func unavailableProvidersDontStartASignIn() {
        let (m, backend) = model()
        var result: Result<CloudAccount, CloudConnectError>?
        _ = m.connect(.oneDrive, openBrowser: { _ in }, done: { result = $0 })
        #expect(!backend.isSigningIn)
        guard case .failure(.failed) = result else { Issue.record("expected a failure"); return }
    }

    @Test func titlesNameTheAccountOnlyWhenThereAreSeveral() {
        let (m, _) = model([personal])
        #expect(m.title("a1") == "Google Drive")
        let (both, _) = model([personal, work])
        #expect(both.title("a1") == "Google Drive · daniel")
        #expect(both.title("a2") == "Google Drive · studio.com")
        // Headers carry the provider's mark: with several accounts they show only the names.
        #expect(both.sections().map(\.title) == ["daniel", "studio.com"])
        both.setLabel("a2", "  work ")
        #expect(both.title("a2") == "Google Drive · work")
        both.setLabel("a2", "")
        #expect(both.label("a2") == "studio.com")
        #expect(both.title("missing") == "")
    }

    @Test func rowsFollowTheChoicesAndSharedDrivesNeedSome() {
        let (m, _) = model([personal, work])
        #expect(m.availableRows("a1") == [.myDrive, .sharedWithMe])
        #expect(m.availableRows("a2") == [.myDrive, .sharedWithMe, .sharedDrives])
        m.setShows(.sharedWithMe, for: "a2", false)
        let section = m.sections().first { $0.id == "a2" }
        #expect(section?.entries.map(\.title) == ["My Drive", "Shared drives"])
        #expect(section?.entries.allSatisfy { $0.section == .account("a2") } == true)
        m.setShows(.sharedWithMe, for: "a2", true)
        #expect(m.shows(.sharedWithMe, for: "a2"))
        // My Drive carries the quota bar when the quota is known.
        let first = m.sections().first { $0.id == "a1" }
        #expect(first?.entries.first?.isVolume == true && first?.quotaTotal == 15_000_000_000)
        #expect(m.sections().first { $0.id == "a2" }?.entries.first?.isVolume == false)
    }

    @Test func statusAndAvatarReachTheSidebar() {
        let backend = DemoCloudBackend()
        backend.avatars["a1"] = Data([1, 2, 3])
        _ = backend.connect(.googleDrive, openBrowser: { _ in }, done: { _ in })
        backend.finishSignIn(personal)
        let m = CloudAccounts()
        m.backend = backend
        backend.setStatus("a1", .signInNeeded)
        #expect(m.sections().first?.status == .signInNeeded)
        // Fetched once, then kept.
        _ = m.avatar("a1")
        #expect(m.avatar("a1") == Data([1, 2, 3]))
        backend.setStatus("a1", .offline)
        #expect(PlacesModel.shared.accounts.first?.status == .offline)
        #expect(PlacesModel.shared.accounts.first?.avatar == Data([1, 2, 3]))
    }

    @Test func signingInAgainOnlyRepeatsTheBrowserStep() {
        let (m, backend) = model([personal])
        backend.setStatus("a1", .signInNeeded)
        var done: Result<Void, CloudConnectError>?
        _ = m.signInAgain("a1", openBrowser: { _ in }, done: { done = $0 })
        backend.finishSignIn(personal)
        if case .success = done {} else { Issue.record("sign-in again failed") }
        #expect(m.account("a1")?.status == .ok)
        #expect(m.accounts.count == 1)
    }

    @Test func removingForgetsChoicesAndSection() {
        let (m, _) = model([personal, work])
        m.setLabel("a1", "home")
        m.setShows(.sharedWithMe, for: "a1", false)
        var finished = false
        m.remove("a1") { _ in finished = true }
        #expect(finished)
        #expect(m.accounts.map(\.id) == ["a2"])
        #expect(m.label("a1") == "")
        #expect(m.shows(.sharedWithMe, for: "a1"))
        #expect(!PlacesModel.shared.sections().map(\.0).contains(.account("a1")))
    }

    @Test func placesIntoAnAccountAreFound() {
        let (m, _) = model([personal])
        let folder = URL(string: "gdrive://a1/folder/XYZ")!
        PlacesModel.shared.add(folder, title: "Design")
        defer { PlacesModel.shared.userEntries.filter { $0.url == folder }.forEach(PlacesModel.shared.remove) }
        let entry = PlacesModel.shared.userEntries.first { $0.url == folder }
        #expect(entry?.section == .places && entry?.icon == "folder-cloud")
        #expect(m.places(of: "a1").map(\.title) == ["Design"])
        #expect(m.account(for: folder) == personal)
        #expect(m.account(for: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func linksAreRecognizedBeforeAskingTheBackend() {
        let (m, backend) = model([personal])
        let link = "https://drive.google.com/drive/folders/XYZ"
        backend.links[link] = .folder(URL(string: "gdrive://a1/folder/XYZ")!)
        var got: CloudLinkResult?
        m.resolveLink(link) { got = $0 }
        #expect(got == .folder(URL(string: "gdrive://a1/folder/XYZ")!))
        m.resolveLink("https://example.com/drive/folders/XYZ") { got = $0 }
        #expect(got == .notALink)
        m.resolveLink("https://docs.google.com/document/d/abc") { got = $0 }
        #expect(got == .noAccess)
        #expect(!CloudAccounts.looksLikeLink("http://drive.google.com/x"))
    }

    @Test func exportPresetDefaultsToOffice() {
        let m = CloudAccounts()
        #expect(m.exportPreset == "office")
        m.exportPreset = "pdf"
        #expect(Settings.store.string(forKey: CloudAccounts.exportPresetKey) == "pdf")
    }

    @Test func sharingSummaryReadsLikeASentence() {
        #expect(CloudItemInfo(sharedWithCount: 4, anyoneWithLink: "can view").sharingSummary == "4 people and anyone with the link (can view)")
        #expect(CloudItemInfo(sharedWithCount: 1).sharingSummary == "1 person")
        #expect(CloudItemInfo(sharedWithCount: 0).sharingSummary == "Only the owner")
        #expect(CloudItemInfo().sharingSummary == nil)
    }

    @Test func providersAndRootsHaveNamesAndMarks() {
        #expect(CloudProvider.allCases.filter(\.isAvailable) == [.googleDrive, .dropbox])
        #expect(CloudProvider.allCases.map(\.brand) == ["google-drive", "dropbox", "onedrive", "box"])
        #expect(CloudProvider.allCases.map(\.title) == ["Google Drive", "Dropbox", "OneDrive", "Box"])
        #expect(CloudRoot.allCases.map(\.title) == ["My Drive", "Shared with me", "Shared drives"])
        #expect(Set(CloudRoot.allCases.map(\.icon)).count == 3)
    }
}

/// Account sections in places.json and the section order.
@MainActor @Suite struct AccountSectionTests {
    private func account(_ id: String) -> AccountSection {
        AccountSection(
            id: id, title: "Google Drive", email: "\(id)@x.com", displayName: id, brand: "google-drive",
            entries: [PlaceEntry(title: "My Drive", url: URL(string: "gdrive://\(id)/my-drive")!, icon: "folder-cloud", section: .account(id))])
    }

    @Test func accountSectionsFollowRemoteUntilMoved() throws {
        let scratch = try Scratch()
        let m = PlacesModel(storeURL: scratch.path("places.json"))
        m.accounts = [account("a"), account("b")]
        let order = m.sections().map(\.0)
        let remote = try #require(order.firstIndex(of: .remote))
        #expect(Array(order[remote + 1...remote + 2]) == [.account("a"), .account("b")])
        #expect(m.title(of: .account("a")) == "Google Drive" && m.title(of: .tags) == "Tags")
        // Moved to the top, it stays there across launches; a removed account's place in the order is forgotten.
        m.moveSection(.account("b"), before: .places)
        let reloaded = PlacesModel(storeURL: scratch.path("places.json"))
        reloaded.accounts = [account("a"), account("b")]
        #expect(reloaded.sections().first?.0 == .account("b"))
        reloaded.accounts = [account("a")]
        #expect(!reloaded.sections().map(\.0).contains(.account("b")))
        #expect(reloaded.title(for: URL(string: "gdrive://a/my-drive")!) == "My Drive")
    }

    @Test func sectionNamesRoundTripAndRetiredOnesAreDropped() throws {
        let data = try JSONEncoder().encode([PlaceSection.account("x"), .places])
        #expect(try JSONDecoder().decode([PlaceSection].self, from: data) == [.account("x"), .places])
        #expect(PlaceSection(stored: "account:x")?.accountID == "x")
        #expect(PlaceSection(stored: "Sync") == nil)
        #expect(PlaceSection.places.accountID == nil)
    }
}
