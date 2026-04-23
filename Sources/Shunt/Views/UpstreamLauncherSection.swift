import SwiftUI
import ShuntCore

/// "Launch before connecting" section rendered inside `UpstreamTab`. Shows the
/// user's prerequisite stages and entries, mutating the model via the
/// launcher-CRUD methods on `SettingsViewModel`. Editing a single entry opens
/// a modal sheet (`LauncherEntryEditor`).
///
/// Live state pills come from `ProxyActivity` — the engine pushes an event
/// per entry transition, which becomes the pill label/colour here.
struct UpstreamLauncherSection: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject private var activity = ProxyActivity.shared
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    @State private var editing: LauncherEntryEditorContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                label: "Launch before connecting",
                icon: "play.square",
                tooltip: "Commands Shunt runs before enabling the tunnel (and stops after disabling). Entries within a stage start in parallel; stages run one after another. A probe that already passes means the entry is already running — Shunt leaves it alone and will not stop it on Disable."
            )

            HStack(spacing: 10) {
                Text("Entries in the same stage start in parallel; stages run sequentially. Each entry's health probe decides when it's \"ready\".")
                    .font(.shuntCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !activity.entries.isEmpty {
                    readyBadge
                }
            }
            .padding(.bottom, 4)

            if model.settings.launcher.stages.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(model.settings.launcher.stages.enumerated()), id: \.element.id) { stageIdx, stage in
                        stageCard(stageIdx: stageIdx, stage: stage)
                    }
                }
            }

            HStack {
                Button {
                    model.addLauncherStage()
                } label: {
                    Label("Add stage", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.top, 6)
        }
        .sheet(item: $editing) { ctx in
            LauncherEntryEditor(
                entry: ctx.entry,
                onSave: { updated in
                    model.updateLauncherEntry(stageID: ctx.stageID, entry: updated)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No prerequisites configured.")
                .font(.shuntLabel)
                .foregroundStyle(.secondary)
            Text("Use this when your upstream SOCKS5 lives inside a VM, SSH tunnel, or container that needs to be brought up before the tunnel is enabled. Common examples: `tart run --no-graphics vm-name`, `ssh -N -D 1080 bastion`, `sshuttle -r user@host 0/0`.")
                .font(.shuntCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Stage card

    @ViewBuilder
    private func stageCard(stageIdx: Int, stage: UpstreamLauncherStage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent(for: scheme).opacity(0.85))
                Text(stage.name.isEmpty ? "Stage \(stageIdx + 1)" : stage.name)
                    .font(.shuntLabel.weight(.medium))
                Text("\(stage.entries.count) \(stage.entries.count == 1 ? "entry" : "entries")")
                    .font(.shuntCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Rename…") { renameStage(stage) }
                    Button(role: .destructive) {
                        model.removeLauncherStage(stageID: stage.id)
                    } label: {
                        Text("Delete stage")
                    }
                    .disabled(!stage.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 16, height: 16)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if stage.entries.isEmpty {
                HStack {
                    Text("No entries in this stage yet.")
                        .font(.shuntCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stage.entries.enumerated()), id: \.element.id) { entryIdx, entry in
                        entryRow(stage: stage, entry: entry, entryIdx: entryIdx)
                        if entryIdx < stage.entries.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    model.addLauncherEntry(to: stage.id)
                } label: {
                    Label("Add entry", systemImage: "plus")
                        .font(.shuntCaption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.accent(for: scheme))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Entry row

    @ViewBuilder
    private func entryRow(stage: UpstreamLauncherStage, entry: UpstreamLauncherEntry, entryIdx: Int) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(entry.enabled ? Color.secondary.opacity(0.6) : Color.secondary.opacity(0.25))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name.isEmpty ? "Untitled" : entry.name)
                    .font(.shuntLabel)
                Text(entry.startCommand.isEmpty ? "(no start command)" : entry.startCommand)
                    .font(.shuntMonoData)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()

            entryStatusPill(for: entry)

            Menu {
                Button("Edit…") {
                    editing = LauncherEntryEditorContext(stageID: stage.id, entry: entry)
                }
                Divider()
                Button("Move up") {
                    model.moveLauncherEntryUp(stageID: stage.id, entryID: entry.id)
                }
                .disabled(entryIdx == 0)
                Button("Move down") {
                    model.moveLauncherEntryDown(stageID: stage.id, entryID: entry.id)
                }
                .disabled(entryIdx == stage.entries.count - 1)
                Divider()
                Button("Promote to own stage") {
                    model.promoteEntryToOwnStage(stageID: stage.id, entryID: entry.id)
                }
                Button("Merge with previous stage") {
                    model.mergeEntryWithPreviousStage(stageID: stage.id, entryID: entry.id)
                }
                .disabled(model.settings.launcher.stages.first?.id == stage.id)
                Divider()
                Button(role: .destructive) {
                    model.removeLauncherEntry(stageID: stage.id, entryID: entry.id)
                } label: {
                    Text("Delete entry")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editing = LauncherEntryEditorContext(stageID: stage.id, entry: entry)
        }
    }

    // MARK: - Ready badge (N/M ready)

    private var readyBadge: some View {
        let ready = activity.runningCount
        let total = activity.entries.count
        let allReady = ready == total
        let color: Color = allReady
            ? theme.statusActive(for: scheme)
            : theme.accent(for: scheme)
        return HStack(spacing: 6) {
            if activity.busy {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text("\(ready)/\(total) ready")
                .font(.shuntMonoLabel)
                .kerning(0.6)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Entry status pill (live, from engine events)

    /// Renders a pill describing the entry's *live* state, falling back to
    /// the probe-type badge when no engine event has been received for this
    /// entry yet (fresh state, tunnel disabled).
    private func entryStatusPill(for entry: UpstreamLauncherEntry) -> some View {
        let progress = activity.entries[entry.id]
        return Group {
            if let progress {
                stateLabel(progress)
            } else {
                probeBadge(for: entry.healthProbe)
            }
        }
    }

    private func stateLabel(_ progress: ProxyActivity.EntryProgress) -> some View {
        let (label, color) = stateStyle(progress)
        return HStack(spacing: 4) {
            Text(label)
                .font(.shuntMonoLabel)
                .kerning(0.6)
                .foregroundStyle(color)
            if case .running = progress.state, !progress.ownedByUs {
                // Subtle marker: this running process was already up when
                // Shunt enabled; on Disable we will not stop it.
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(color.opacity(0.7))
                    .help("Pre-existing process — Shunt didn't start it and won't stop it on Disable.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }

    private func stateStyle(_ progress: ProxyActivity.EntryProgress) -> (String, Color) {
        switch progress.state {
        case .idle:
            return ("IDLE", .secondary)
        case .starting:
            return ("STARTING", theme.accent(for: scheme))
        case .running:
            return ("RUNNING", theme.statusActive(for: scheme))
        case .failed:
            return ("FAILED", .red)
        case .stopping:
            return ("STOPPING", theme.accent(for: scheme))
        case .stopped:
            return ("STOPPED", .secondary)
        }
    }

    // MARK: - Probe badge (static fallback)

    private func probeBadge(for probe: HealthProbe) -> some View {
        let label: String = {
            switch probe {
            case .portOpen: return "port open"
            case .socks5Handshake: return "socks5"
            case .egressCidrMatch: return "cidr"
            case .egressDiffersFromDirect: return "egress differs"
            }
        }()
        return Text(label.uppercased())
            .font(.shuntMonoLabel)
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: - Stage rename

    private func renameStage(_ stage: UpstreamLauncherStage) {
        let alert = NSAlert()
        alert.messageText = "Rename stage"
        alert.informativeText = "Give this stage a short descriptive name (e.g. “VM boot”, “Tunnels”)."
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = stage.name
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                model.renameLauncherStage(stageID: stage.id, to: trimmed)
            }
        }
    }
}

/// Identifies which entry is being edited in the sheet. `Identifiable` so
/// we can drive `.sheet(item:)`.
struct LauncherEntryEditorContext: Identifiable {
    var id: UUID { entry.id }
    let stageID: UUID
    var entry: UpstreamLauncherEntry
}
