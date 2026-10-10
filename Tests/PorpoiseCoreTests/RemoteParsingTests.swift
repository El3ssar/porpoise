import Foundation
import Testing
@testable import PorpoiseCore

@Suite struct RemoteParsingTests {
    let folder = URL(string: "sftp://me@host/home/me/")!

    @Test func gnuFind() {
        let out = "d\t4096\t1700000000.5\t755\tme\tstaff\t\tsrc\nf\t12\t1700000001.0\t644\tme\tstaff\t\tnotes with space.txt\nl\t7\t1700000002\t777\tme\tstaff\t/etc/hosts\thosts\n"
        let items = RemoteParsing.parseFind(out, folder: folder)
        #expect(items.map(\.name) == ["src", "notes with space.txt", "hosts"])
        #expect(items[0].isDirectory && items[0].posixPermissions == 0o755)
        #expect(items[1].size == 12 && items[1].url.absoluteString.hasPrefix("sftp://me@host/home/me/notes"))
        #expect(items[2].isSymlink && items[2].linkDestination == "/etc/hosts")
    }

    @Test func namesKeepLeadingSpacesAndTrailingNewlines() {
        // ls: exactly one space before the name, so " a.txt" stays " a.txt" (not "a.txt", another file).
        let ls = "-rw-r--r--    1 me   me   12 Jan  5  2024  a.txt\n-rw-r--r--    1 me   me   12 Jan  5  2024 a.txt\n"
        #expect(RemoteParsing.parseLsLong(ls, folder: URL(string: "ftp://h/")!).map(\.name) == [" a.txt", "a.txt"])
        // find records end in the name itself: a name ending in a newline keeps it.
        let find = "f\t1\t1700000000\t644\tme\tstaff\t\tfoo\n\0f\t1\t1700000000\t644\tme\tstaff\t\tfoo\0__GNU__\n"
        #expect(RemoteParsing.parseFind(find, folder: folder).map(\.name) == ["foo\n", "foo"])
        // stat prints a newline before each NUL; that one isn't part of the name.
        let stat = "Regular File\t1\t1700000000\t644\tme\tstaff\t\t./foo\n\0"
        #expect(RemoteParsing.parseBSDStat(stat, folder: folder).map(\.name) == ["foo"])
    }

    @Test func ftpLsLong() {
        let now = DateComponents(calendar: .current, year: 2026, month: 10, day: 8).date!
        let out = """
        drwxr-xr-x    2 1000     1000         4096 Jan  5  2024 pub
        -rw-r--r--    1 ftp      ftp       1048576 Oct  7 14:30 big file.iso
        lrwxrwxrwx    1 0        0              11 Mar 12 09:00 latest -> pub/v1.tar
        """
        let items = RemoteParsing.parseLsLong(out, folder: URL(string: "ftp://h/")!, now: now)
        #expect(items.map(\.name) == ["pub", "big file.iso", "latest"])
        #expect(items[0].isDirectory)
        #expect(items[1].size == 1_048_576)
        #expect(Calendar.current.component(.year, from: items[1].modificationDate!) == 2026)
        #expect(items[2].linkDestination == "pub/v1.tar")
    }

    @Test func androidToybox() {
        let out = """
        total 24
        drwxrwx--x  4 root sdcard_rw 3452 2024-05-01 10:12 .
        drwxrwx--x  4 root sdcard_rw 3452 2024-05-01 10:12 ..
        drwxrws---  2 u0_a1 media_rw 3452 2025-02-03 08:00 DCIM
        -rw-rw----  1 u0_a1 media_rw 2048 2025-02-03 08:01 photo.jpg
        """
        let items = RemoteParsing.parseLsLong(out, folder: URL(string: "adb://SER/sdcard/")!)
        #expect(items.map(\.name) == ["DCIM", "photo.jpg"])
        #expect(items[1].size == 2048 && items[1].modificationDate != nil)
    }

    @Test func adbDevices() {
        let out = "List of devices attached\nR58N123 device usb:1-1 product:x model:Galaxy_S21 device:o1s\nemulator-5554 offline\n"
        let d = RemoteParsing.parseADBDevices(out)
        #expect(d.count == 1 && d[0].serial == "R58N123" && d[0].model == "Galaxy S21")
    }

    @Test func quoting() {
        #expect(RemoteParsing.quote("it's") == "'it'\\''s'")
    }
}

@Suite struct RemoteParsingEdgeCaseTests {
    let folder = URL(string: "sftp://me@host/home/me/")!

    private func gnu(_ type: String, _ name: String, link: String = "") -> String {
        "\(type)\t10\t1700000000\t644\tme\tstaff\t\(link)\t\(name)"
    }

    @Test func findWithNulRecordsAllowsNewlinesAndTabs() {
        let out = [gnu("ff", "multi\nline.txt"), gnu("ff", "tab\there"), gnu("dd", "ünïcødé 📁"), gnu("ff", "  spaced  ")]
            .joined(separator: "\0") + "\0"
        let items = RemoteParsing.parseFind(out, folder: folder)
        #expect(items.map(\.name) == ["multi\nline.txt", "tab\there", "ünïcødé 📁", "  spaced  "])
        #expect(items[2].isDirectory && items[2].url.lastPathComponent == "ünïcødé 📁")
    }

    @Test func findLinkTypes() {
        let out = [gnu("ld", "to-dir", link: "/srv"), gnu("lN", "broken", link: "/gone"), gnu("ff", "a -> b")].joined(separator: "\n")
        let items = RemoteParsing.parseFind(out, folder: folder)
        #expect(items[0].isSymlink && items[0].isDirectory)      // links to folders browse
        #expect(items[1].isSymlink && !items[1].isDirectory && items[1].linkDestination == "/gone")
        #expect(items[2].name == "a -> b" && items[2].linkDestination == nil)
    }

    @Test func unsafeNamesAreDropped() {
        let out = [gnu("ff", "../../etc/passwd"), gnu("ff", "a/b"), gnu("ff", ".."), gnu("ff", ""), gnu("ff", "ok")].joined(separator: "\0")
        #expect(RemoteParsing.parseFind(out, folder: folder).map(\.name) == ["ok"])
        let ls = "-rw-r--r-- 1 u g 1 Jan  1  2024 ../evil\n-rw-r--r-- 1 u g 1 Jan  1  2024 fine\n"
        #expect(RemoteParsing.parseLsLong(ls, folder: folder).map(\.name) == ["fine"])
    }

    @Test func bsdStatWithDotSlashNamesAndNulRecords() {
        let rec = { (t: String, n: String) in "\(t)\t5\t1700000000\t755\tme\tstaff\t\t./\(n)\n" }
        let out = rec("Directory", "dir") + "\0" + rec("Regular File", "*") + "\0" + rec("Symbolic Link", "new\nline") + "\0"
        let items = RemoteParsing.parseBSDStat(out, folder: folder)
        #expect(items.map(\.name) == ["dir", "*", "new\nline"])   // a real file named "*" is kept
        #expect(items[0].isDirectory && items[2].isSymlink)
    }

    @Test func lsDeviceFilesAndMissingGroup() {
        let now = DateComponents(calendar: .current, year: 2026, month: 10, day: 8).date!
        let out = """
        crw-rw-rw-  1 root root   1,   3 2025-01-01 00:00 null
        brw-rw----  1 root disk 259,0 2025-01-01 00:00 nvme0n1
        -rw-r--r--  1 ftp        42 Jan  5  2024 nogroup.txt
        prw-r--r--  1 me   me      0 Oct  7 10:00 fifo
        """
        let items = RemoteParsing.parseLsLong(out, folder: URL(string: "adb://S/dev/")!, now: now)
        #expect(items.map(\.name) == ["null", "nvme0n1", "nogroup.txt", "fifo"])
        #expect(items[0].size == 0 && items[0].modificationDate != nil)
        #expect(items[2].size == 42 && items[2].group == nil && items[2].owner == "ftp")
    }

    @Test func lsNamesWithArrowsSpacesAndCRLF() {
        let now = DateComponents(calendar: .current, year: 2026, month: 10, day: 8).date!
        let out = "-rw-r--r-- 1 u g 3 Oct  7 14:30 a -> b.txt\r\nlrwxrwxrwx 1 u g 3 Oct  7 14:30 my link -> target with spaces\r\n"
            + "-rw-r--r-- 1 u g 3 Oct  7 14:30 日本語 ファイル.txt\r\n"
        let items = RemoteParsing.parseLsLong(out, folder: URL(string: "ftp://h/")!, now: now)
        #expect(items.map(\.name) == ["a -> b.txt", "my link", "日本語 ファイル.txt"])
        #expect(items[0].linkDestination == nil && items[1].linkDestination == "target with spaces")
    }

    @Test func lsDatesYearGuessAndTimeZone() throws {
        let gmt = TimeZone(identifier: "GMT")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = gmt
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!
        // "Dec 30" without a year is in the past: last year, not next December.
        let d = try #require(RemoteParsing.parseLsDate(["Dec", "30", "08:15"], now: now, timeZone: gmt))
        #expect(cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                == DateComponents(year: 2025, month: 12, day: 30, hour: 8, minute: 15))
        let iso = try #require(RemoteParsing.parseLsDate(["2024-02-29", "23:59:59.000"], now: now, timeZone: gmt))
        #expect(cal.component(.day, from: iso) == 29)
        #expect(RemoteParsing.parseLsDate(["Foo", "1", "2024"], now: now) == nil)
        #expect(RemoteParsing.parseLsDate(["Jan"], now: now) == nil)
    }

    @Test func permissionBits() {
        #expect(RemoteParsing.parsePerms("drwxr-xr-x") == 0o755)
        #expect(RemoteParsing.parsePerms("-rwsr-xr-x") == 0o4755)
        #expect(RemoteParsing.parsePerms("-rwSr--r--") == 0o4644)
        #expect(RemoteParsing.parsePerms("drwxrws---") == 0o2770)
        #expect(RemoteParsing.parsePerms("drwxrwxrwt") == 0o1777)
        #expect(RemoteParsing.parsePerms("-rw-r--r--@") == 0o644)
        #expect(RemoteParsing.parsePerms("short") == 0o644)
    }

    @Test func adbDeviceStates() {
        let out = "List of devices attached\n192.168.1.5:5555 device product:p model:Pixel_8 transport_id:2\nABC unauthorized usb:1\n\n"
        let d = RemoteParsing.parseADBDevices(out)
        #expect(d.count == 1 && d[0].serial == "192.168.1.5:5555" && d[0].model == "Pixel 8")
        #expect(RemoteParsing.parseADBDevices("List of devices attached\nXYZ device\n")[0].model == "XYZ")
    }

    @Test func quotingIsOneShellWord() {
        for s in ["", "a b", "$(rm -rf ~)", "`x`", "a'b'c", "line\nbreak", "-rf", "\\"] {
            let q = RemoteParsing.quote(s)
            #expect(q.hasPrefix("'") && q.hasSuffix("'"))
            #expect(q.replacingOccurrences(of: "'\\''", with: "").dropFirst().dropLast().contains("'") == false)
        }
    }

    @Test func safeNames() {
        #expect(RemoteParsing.isSafeName("a b.txt") && RemoteParsing.isSafeName("..."))
        #expect(!RemoteParsing.isSafeName("") && !RemoteParsing.isSafeName("..") && !RemoteParsing.isSafeName("a/b"))
        #expect(!RemoteParsing.isSafeName("nul\0"))
    }
}
