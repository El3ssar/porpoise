import AppKit
import PorpoiseCore
import PorpoiseServices

extension ItemListView {
    /// Only visible date labels need a clock. One wakeup at the next label boundary;
    /// no background polling, metadata reads or directory-wide scan.
    func scheduleRelativeDateRefresh(now: Date = Date(), calendar: Calendar = .current) {
        guard window?.occlusionState.contains(.visible) == true, !isHiddenOrHasHiddenAncestor,
            Settings.shared.dateStyle == .relative
        else { stopRelativeDateRefresh(); return }
        let roles = visibleDateRoles()
        guard !roles.isEmpty else { stopRelativeDateRefresh(); return }
        let dates = candidateIndexes(in: visibleRect).flatMap { i in roles.compactMap { model.rows[i].item.date(for: $0) } }
        guard let next = Self.nextRelativeDateRefresh(dates: dates, now: now, calendar: calendar) else {
            stopRelativeDateRefresh(); return
        }
        if let timer = relativeDateTimer, abs(timer.fireDate.timeIntervalSince(next)) < 0.5 { return }
        stopRelativeDateRefresh()
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.relativeDateTimer = nil
            guard self.window?.occlusionState.contains(.visible) == true, !self.isHiddenOrHasHiddenAncestor else { return }
            // Refresh visible strings in place. A Compact relayout would measure every
            // label in large folders and make the columns jump once per minute. The
            // width cache refreshes on a real layout after the next clock minute or
            // a content/settings change; longer labels elide safely in the meantime.
            self.needsDisplay = true
        }
        timer.tolerance = 0.5
        relativeDateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func visibleDateRoles() -> [ItemRole] {
        let dates: Set<ItemRole> = [.modificationTime, .creationTime, .accessTime, .sharedTime]
        guard mode == .details else { return model.props.roles(for: mode).filter(dates.contains) }
        var x = Self.sidePadding
        return detailsRoles.filter { role in
            let width = columnWidths[role] ?? role.defaultColumnWidth
            defer { x += width }
            return dates.contains(role) && x + width > visibleRect.minX && x < visibleRect.maxX
        }
    }

    static func nextRelativeDateRefresh(dates: [Date], now: Date, calendar: Calendar) -> Date? {
        guard !dates.isEmpty else { return nil }
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        return dates.reduce(midnight) { next, date in
            let elapsed = now.timeIntervalSince(date)
            let boundary: Date?
            if elapsed < 0 {
                boundary = date.addingTimeInterval(0.01)
            } else if elapsed < 3600 {
                boundary = date.addingTimeInterval((floor(elapsed / 60) + 1) * 60 + 0.01)
            } else {
                boundary = midnight
            }
            return [next, boundary].compactMap { $0 }.min()
        }
    }

    func stopRelativeDateRefresh() {
        relativeDateTimer?.invalidate()
        relativeDateTimer = nil
    }

    /// Date columns expose their full timestamp even when the general item tooltip is off.
    func dateToolTip(at point: CGPoint, row: Int) -> String? {
        guard mode == .details, row >= 0, row < model.rows.count else { return nil }
        var x = Self.sidePadding
        for role in detailsRoles {
            let width = columnWidths[role] ?? role.defaultColumnWidth
            defer { x += width }
            guard point.x >= x, point.x < x + width else { continue }
            guard let date = model.rows[row].item.date(for: role) else { return nil }
            return "\(role.title): \(FileFormat.exactDate(date))"
        }
        return nil
    }
}
