import Foundation
import Testing

@testable import PorpoiseCore

struct FileFormattingCacheTests {
    @Test func speedsAndLimitLabelsUseTheSizeUnitBase() {
        #expect(FileFormat.speed(1023) == "1023 B/s")
        #expect(FileFormat.speed(1024) == FileFormat.size(1024) + "/s")
        #expect(FileFormat.speed(1_048_576) == "1.0 MiB/s")
        #expect(FileFormat.speed(-1) == "0 B/s")
        #expect(FileFormat.speed(.nan) == "0 B/s" && FileFormat.speed(.infinity) == "0 B/s")
        #expect(FileFormat.speed(Double.greatestFiniteMagnitude) == FileFormat.size(Int64.max) + "/s")
        #expect(FileFormat.byteLimitTitle(1 << 30) == "1 GiB")
        #expect(FileFormat.byteLimitTitle(5 << 30) == "5 GiB")
        #expect(FileFormat.byteLimitTitle(nil) == "No limit")
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
