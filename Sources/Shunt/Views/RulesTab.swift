import SwiftUI
import AppKit
import ShuntCore

// Compound routing rules. Each rule answers the question "for these apps
// going to these hosts, do X." Apps empty = any app; hosts empty = any host;
// action = route (through upstream) or direct (force passthrough).
//
// Replaces the v0.1 Apps tab. Migration from the v1 model happens in
// ShuntSettings.init(from:) — 1 app becomes 1 rule with hosts=[], route.

struct RulesTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var selection: Set<UUID> = []
    @State private var expanded: Set<UUID> = []
    @State private var focusedRuleID: UUID?
    @FocusState private var focusedBundleID: UUID?
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rules")
                    .font(.shuntTitle1)
                Text("Combine apps and hostnames into compound rules. A rule matches when every criterion is satisfied — \"Safari AND *.corp.com\" only routes Safari's traffic to corp domains.")
                    .font(.shuntBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 16)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        if model.settings.rules.isEmpty {
                            EmptyRulesState()
                                .padding(.vertical, 40)
                        } else {
                            ForEach($model.settings.rules) { $rule in
                                RuleCard(
                                    rule: $rule,
                                    isSelected: selection.contains(rule.id),
                                    isExpanded: expanded.contains(rule.id),
                                    theme: theme,
                                    scheme: scheme,
                                    focusedBundleID: $focusedBundleID,
                                    onToggleSelect: {
                                        if selection.contains(rule.id) {
                                            selection.remove(rule.id)
                                        } else {
                                            selection.insert(rule.id)
                                        }
                                    },
                                    onToggleExpand: {
                                        withAnimation(.easeOut(duration: 0.18)) {
                                            if expanded.contains(rule.id) {
                                                expanded.remove(rule.id)
                                            } else {
                                                expanded.insert(rule.id)
                                            }
                                        }
                                    },
                                    onCommit: { model.save() },
                                    onToggleEnabled: { model.toggleRule(id: rule.id) },
                                    onPickApp: { addAppFromPanel(ruleID: rule.id) },
                                    onAddAppByBundleID: { addAppByBundleID(ruleID: rule.id, proxy: proxy) },
                                    onRemoveApp: { appID in
                                        model.removeAppFromRule(ruleID: rule.id, appID: appID)
                                    },
                                    onEnrichApp: { appID in
                                        model.enrichAppInRule(ruleID: rule.id, appID: appID)
                                    },
                                    onAddHost: { _ = model.addHostToRule(ruleID: rule.id) },
                                    onRemoveHost: { hostID in
                                        model.removeHostFromRule(ruleID: rule.id, hostID: hostID)
                                    }
                                )
                                .id(rule.id)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                }

                // Action bar
                HStack(spacing: 8) {
                    Button {
                        let newID = model.addRule()
                        expanded.insert(newID)
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(newID, anchor: .bottom)
                            }
                        }
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent(for: scheme))

                    Button {
                        if let mergedID = model.mergeRules(ids: selection) {
                            selection = [mergedID]
                            expanded.insert(mergedID)
                        }
                    } label: {
                        Label("Merge (\(selection.count))", systemImage: "arrow.triangle.merge")
                    }
                    .disabled(selection.count < 2)

                    Spacer()

                    Button(role: .destructive) {
                        model.removeRules(ids: selection)
                        selection.removeAll()
                    } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(selection.isEmpty)
                }
                .padding(16)
            }
        }
    }

    // MARK: - Actions

    private func addAppFromPanel(ruleID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "Add an app to this rule"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let info = model.importAppBundle(at: url) else {
            model.lastError = "Couldn't read bundle info from the selected app"
            return
        }

        // Always add the main app first.
        model.addAppToRule(
            ruleID: ruleID,
            bundleID: info.bundleID,
            displayName: info.name,
            appPath: url.path
        )

        // Scan for helper bundles (Chromium/Electron multi-process apps route
        // traffic through helpers — unless we add them, flows never get claimed).
        let helpers = model.findHelperBundles(in: url, parentBundleID: info.bundleID)
        guard !helpers.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Add \(helpers.count) helper \(helpers.count == 1 ? "bundle" : "bundles")?"
        let helperList = helpers.map { "• \($0.bundleID)" }.joined(separator: "\n")
        alert.informativeText = """
        \(info.name) ships with \(helpers.count) helper \(helpers.count == 1 ? "bundle" : "bundles"):

        \(helperList)

        Multi-process apps like Chrome and Electron route network traffic through these helpers instead of the main process. Adding them ensures all traffic from \(info.name) is claimed.
        """
        alert.addButton(withTitle: "Add Main + Helpers")
        alert.addButton(withTitle: "Add Main Only")
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            for helper in helpers {
                model.addAppToRule(
                    ruleID: ruleID,
                    bundleID: helper.bundleID,
                    displayName: helper.name,
                    appPath: helper.path
                )
            }
        }
    }

    private func addAppByBundleID(ruleID: UUID, proxy: ScrollViewProxy) {
        if let newAppID = model.addEmptyAppToRule(ruleID: ruleID) {
            expanded.insert(ruleID)
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(ruleID, anchor: .bottom)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    focusedBundleID = newAppID
                }
            }
        }
    }
}

// MARK: - Rule card (header + body)

private struct RuleCard: View {
    @Binding var rule: Rule
    let isSelected: Bool
    let isExpanded: Bool
    let theme: ShuntTheme
    let scheme: ColorScheme
    @FocusState.Binding var focusedBundleID: UUID?
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    let onCommit: () -> Void
    let onToggleEnabled: () -> Void
    let onPickApp: () -> Void
    let onAddAppByBundleID: () -> Void
    let onRemoveApp: (UUID) -> Void
    let onEnrichApp: (UUID) -> Void
    let onAddHost: () -> Void
    let onRemoveHost: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                body2
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? theme.accent(for: scheme) : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 2 : 1
                )
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? theme.accent(for: scheme) : .secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Deselect rule" : "Select rule — hold ⌘ for multi-select, then Merge")

            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse rule body" : "Expand to edit apps, hosts, and action")

            TextField("Rule name", text: $rule.name, onCommit: onCommit)
                .textFieldStyle(.plain)
                .font(.shuntLabelStrong)

            Spacer()

            badge

            Toggle("", isOn: $rule.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(theme.accent(for: scheme))
                .onChange(of: rule.enabled) { _, _ in onCommit() }
                .help(rule.enabled ? "Rule is active — toggle off to disable without deleting" : "Rule is disabled — toggle on to activate")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onToggleExpand)
    }

    private var badge: some View {
        HStack(spacing: 6) {
            badgePiece(
                icon: "square.grid.2x2",
                count: rule.apps.count,
                tooltip: appsTooltip
            )
            badgePiece(
                icon: "globe",
                count: rule.hosts.count,
                tooltip: hostsTooltip
            )
            Text(rule.action == .route ? "route" : "direct")
                .font(.shuntMonoLabel)
                .kerning(0.6)
                .foregroundStyle(rule.action == .route ? theme.accent(for: scheme) : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill((rule.action == .route ? theme.accent(for: scheme) : .secondary).opacity(0.12))
                )
                .contentShape(Rectangle())
                .help(actionTooltip)
        }
    }

    private func badgePiece(icon: String, count: Int, tooltip: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.shuntMonoLabel)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private var appsTooltip: String {
        let n = rule.apps.count
        if n == 0 { return "Any app — this rule doesn't filter by source app" }
        return "\(n) \(n == 1 ? "app" : "apps") matched by bundle ID"
    }

    private var hostsTooltip: String {
        let n = rule.hosts.count
        if n == 0 { return "Any host — this rule doesn't filter by destination" }
        return "\(n) host \(n == 1 ? "pattern" : "patterns") — matching requires the v2 extension"
    }

    private var actionTooltip: String {
        rule.action == .route
            ? "Route: claimed flows are sent through the upstream proxy"
            : "Direct: claimed flows pass through to the host network, overriding any Route rule that would otherwise match"
    }

    private var body2: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Apps
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel(
                        text: "Apps",
                        icon: "square.grid.2x2",
                        tooltip: "Flows are claimed only when the source app's bundle ID matches one of these. Empty = any app."
                    )
                    Spacer()
                    Button("Add from Applications…", action: onPickApp)
                        .buttonStyle(.link)
                        .font(.shuntCaption)
                    Button("Add by Bundle ID", action: onAddAppByBundleID)
                        .buttonStyle(.link)
                        .font(.shuntCaption)
                }
                if rule.apps.isEmpty {
                    emptyListHint(text: "No apps — rule applies to any app.")
                } else {
                    VStack(spacing: 2) {
                        // Iterate by value + construct ID-based bindings.
                        // ForEach($rule.apps) { $app in ... } subscripts the
                        // array by index and crashes (Array._checkSubscript)
                        // when the array mutates during a TextField commit.
                        ForEach(rule.apps) { app in
                            let appID = app.id
                            RuleAppRow(
                                app: appBinding(id: appID, fallback: app),
                                theme: theme,
                                scheme: scheme,
                                focusedBundleID: $focusedBundleID,
                                onCommit: { onEnrichApp(appID) },
                                onRemove: { onRemoveApp(appID) }
                            )
                        }
                    }
                }
            }

            // Hosts
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel(
                        text: "Hosts",
                        icon: "globe",
                        tooltip: "Flows are claimed only when the destination matches one of these patterns. Empty = any host. Host matching needs the v2 extension."
                    )
                    Spacer()
                    Button("Add pattern", action: onAddHost)
                        .buttonStyle(.link)
                        .font(.shuntCaption)
                }
                if rule.hosts.isEmpty {
                    emptyListHint(text: "No host patterns — rule applies to any destination.")
                } else {
                    VStack(spacing: 2) {
                        // Same ID-based binding pattern as apps above.
                        ForEach(rule.hosts) { host in
                            let hostID = host.id
                            RuleHostRow(
                                host: hostBinding(id: hostID, fallback: host),
                                onCommit: onCommit,
                                onRemove: { onRemoveHost(hostID) }
                            )
                        }
                    }
                }
            }

            // Action
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(
                    text: "Action",
                    icon: "arrow.left.arrow.right",
                    tooltip: "Route = send matching flows through the upstream proxy. Direct = pass matching flows through to the host network (overrides other rules)."
                )
                Picker("", selection: Binding(
                    get: { rule.action },
                    set: { rule.action = $0; onCommit() }
                )) {
                    Text("Route through upstream").tag(Rule.Action.route)
                    Text("Direct (override)").tag(Rule.Action.direct)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
            }

            if !rule.isValid {
                Text("Rule matches nothing — add at least one app or one host pattern.")
                    .font(.shuntCaption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
    }

    private func emptyListHint(text: String) -> some View {
        Text(text)
            .font(.shuntCaption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
    }

    // MARK: - ID-based bindings (crash-safe)
    //
    // `ForEach($rule.apps) { $app in ... }` creates per-element bindings that
    // subscript the array by index. When the array mutates (e.g. a TextField
    // commit that triggers save() → objectWillChange → layout pass), those
    // indices can briefly be stale and Array._checkSubscript traps. Looking
    // up the element by its stable id avoids the race entirely.

    private func appBinding(id: UUID, fallback: ManagedApp) -> Binding<ManagedApp> {
        Binding(
            get: { rule.apps.first(where: { $0.id == id }) ?? fallback },
            set: { newValue in
                if let idx = rule.apps.firstIndex(where: { $0.id == id }) {
                    rule.apps[idx] = newValue
                }
            }
        )
    }

    private func hostBinding(id: UUID, fallback: HostPattern) -> Binding<HostPattern> {
        Binding(
            get: { rule.hosts.first(where: { $0.id == id }) ?? fallback },
            set: { newValue in
                if let idx = rule.hosts.firstIndex(where: { $0.id == id }) {
                    rule.hosts[idx] = newValue
                }
            }
        )
    }
}

private struct SectionLabel: View {
    let text: String
    let icon: String?
    let tooltip: String?
    init(text: String, icon: String? = nil, tooltip: String? = nil) {
        self.text = text
        self.icon = icon
        self.tooltip = tooltip
    }
    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(text.uppercased())
                .font(.shuntMonoLabel)
                .kerning(0.8)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help(tooltip ?? "")
    }
}

// MARK: - App row inside a rule

private struct RuleAppRow: View {
    @Binding var app: ManagedApp
    let theme: ShuntTheme
    let scheme: ColorScheme
    @FocusState.Binding var focusedBundleID: UUID?
    let onCommit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Display name", text: $app.displayName, onCommit: onCommit)
                    .textFieldStyle(.plain)
                    .font(.shuntLabel)
                TextField("com.example.app", text: $app.bundleID, onCommit: onCommit)
                    .textFieldStyle(.plain)
                    .font(.shuntMonoData)
                    .foregroundStyle(.secondary)
                    .focused($focusedBundleID, equals: app.id)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var icon: some View {
        if let path = app.appPath, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay(
                    Image(systemName: "app.dashed")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                )
        }
    }
}

// MARK: - Host row inside a rule

private struct RuleHostRow: View {
    @Binding var host: HostPattern
    let onCommit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $host.kind) {
                Text("Exact").tag(HostPattern.Kind.exact)
                Text("Suffix").tag(HostPattern.Kind.suffix)
                Text("CIDR").tag(HostPattern.Kind.cidr)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 92)
            .font(.shuntMonoData)

            TextField(placeholder, text: $host.pattern, onCommit: onCommit)
                .textFieldStyle(.plain)
                .font(.shuntMonoData)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onChange(of: host.kind) { _, _ in onCommit() }
    }

    private var placeholder: String {
        switch host.kind {
        case .exact:  return "teams.microsoft.com"
        case .suffix: return "*.corp.com"
        case .cidr:   return "10.0.0.0/8"
        }
    }
}

private struct EmptyRulesState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No rules configured")
                .font(.shuntLabelStrong)
                .foregroundStyle(.secondary)
            Text("Add a rule to start routing selected apps or hostnames.")
                .font(.shuntCaption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
