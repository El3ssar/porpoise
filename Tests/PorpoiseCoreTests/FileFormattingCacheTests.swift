import Foundation
import Testing

@testable import PorpoiseCore

struct FileFormattingCacheTests {
    @Test func decimalSizesUseFileStyleAndRequestedLocale() {
        let english = Locale(identifier: "en_US")
        #expect(FileFormat.size(0, units: .decimal, locale: english) == "0 B")
        #expect(FileFormat.size(999, units: .decimal, locale: english) == "999 B")
        #expect(FileFormat.size(1000, units: .decimal, locale: english) == "1 KB")
        #expect(FileFormat.size(1_500_000, units: .decimal, locale: english) == "1.5 MB")
        #expect(FileFormat.size(2_000_000_000_000, units: .decimal, locale: english) == "2 TB")
        let german = Locale(identifier: "de_DE")
        #expect(FileFormat.size(999, units: .decimal, locale: german) == "999 B")
        #expect(FileFormat.size(1000, units: .decimal, locale: german) == "1 KB")
        #expect(FileFormat.size(1_500_000, units: .decimal, locale: german) == "1,5 MB")
        #expect(FileFormat.size(2_000_000_000_000, units: .decimal, locale: german) == "2 TB")
        #expect(FileFormat.size(1_500_000, units: .binary, locale: german) == "1.4 MiB")
        #expect(FileFormat.size(Int64.max, units: .decimal, locale: english).hasSuffix("EB"))
    }

    @Test func decimalStatusSizesAreRemovedBeforeTruncatingWords() {
        #expect(FileFormat.fittingStatusMessage("1 file selected (134.1 MB)") { $0.count <= 18 } == "1 file selected")
    }

    @Test func speedsAndLimitLabelsUseTheSizeUnitBase() {
        #expect(FileFormat.speed(1023, units: .binary) == "1023 B/s")
        #expect(FileFormat.speed(1024, units: .binary) == FileFormat.size(1024, units: .binary) + "/s")
        #expect(FileFormat.speed(1_048_576, units: .binary) == "1.0 MiB/s")
        #expect(FileFormat.speed(-1, units: .binary) == "0 B/s")
        #expect(FileFormat.speed(.nan, units: .binary) == "0 B/s" && FileFormat.speed(.infinity, units: .binary) == "0 B/s")
        #expect(FileFormat.speed(Double.greatestFiniteMagnitude, units: .binary) == FileFormat.size(Int64.max, units: .binary) + "/s")
        #expect(FileFormat.byteLimitTitle(1 << 30, units: .binary) == "1 GiB")
        #expect(FileFormat.byteLimitTitle(5 << 30, units: .binary) == "5 GiB")
        #expect(FileFormat.byteLimitTitle(nil, units: .binary) == "No limit")
    }

    @Test func protocolDatesPreserveZonesAndCalendarIdentityConcurrently() async {
        let epoch = Date(timeIntervalSince1970: 0)
        #expect(FileFormat.iso8601(epoch) == "1970-01-01T00:00:00Z")
        #expect(FileFormat.iso8601("1970-01-01T00:00:00Z") == epoch)
        #expect(FileFormat.iso8601("not a date") == nil)
        #expect(FileFormat.posixDate("not a date", format: "yyyy-MM-dd", timeZone: .gmt) == nil)
        let valid = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let zone = TimeZone(secondsFromGMT: i % 2 == 0 ? 0 : 3600)!
                    let expected = i % 2 == 0 ? "1970-01-01 00:00" : "1970-01-01 01:00"
                    let encoded = FileFormat.posixString(epoch, format: "yyyy-MM-dd HH:mm", timeZone: zone)
                    let decoded = FileFormat.posixDate(encoded, format: "yyyy-MM-dd HH:mm", timeZone: zone)
                    let buddhist = Calendar(identifier: .buddhist)
                    return encoded == expected && decoded == epoch
                        && FileFormat.posixString(epoch, format: "yyyy", timeZone: .gmt, calendar: buddhist) == "2513"
                        && FileFormat.posixString(epoch, format: "yyyy", timeZone: .gmt) == "1970"
                }
            }
            var valid = true
            for await result in group { valid = valid && result }
            return valid
        }
        #expect(valid)
    }
}
