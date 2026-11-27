// SPDX-License-Identifier: GPL-3.0-or-later
//
// This file is part of P1Label, a macOS label printing app for the
// Detong P1 thermal label printer.
// Copyright (C) 2026 P1Label authors
//
// P1Label is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
// or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Snapshot-based undo/redo (design spec v2 §5.3). `LabelDocument` is pure
// value types at document scale (<100 elements), so whole-document deep
// copies are effectively free — no incremental diffing.

import Foundation

/// One historical state: the document plus which elements were selected, so
/// undo restores the editor context as well as the content.
struct HistoryEntry: Equatable {
    var doc: LabelDocument
    var selection: Set<UUID>
}

struct HistoryStack {
    /// Past states, oldest first. `entries.last` is the state to restore on
    /// the next undo (the state before the current one).
    private(set) var entries: [HistoryEntry] = []
    /// Future states for redo, most recent next.
    private(set) var redo: [HistoryEntry] = []
    private let limit = 100

    /// Record the state that existed BEFORE a mutation. Clears the redo tail.
    mutating func record(_ entry: HistoryEntry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        redo.removeAll()
    }

    /// Restore the previous state; returns it plus the current state pushed
    /// onto the redo tail. Nil when there is nothing to undo.
    mutating func undo(current: HistoryEntry) -> HistoryEntry? {
        guard let previous = entries.popLast() else { return nil }
        redo.append(current)
        return previous
    }

    /// Re-apply the next undone state; returns it plus the current state
    /// pushed back onto the past. Nil when there is nothing to redo.
    mutating func redo(current: HistoryEntry) -> HistoryEntry? {
        guard let next = redo.popLast() else { return nil }
        entries.append(current)
        return next
    }
}
