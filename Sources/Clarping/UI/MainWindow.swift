import SwiftUI
import Charts

// MARK: - Window

/// Main window: a frosted header strip with the glass tab switcher (the
/// floating functional layer), above solid cream content. Tab content swaps
/// with one short fade / rise / un-blur when `mainTab` changes; nothing loops.
struct MainWindow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Group {
                    switch state.mainTab {
                    case .dashboard: DashboardView()
                    case .settings: SettingsView()
                    }
                }
                .id(state.mainTab)
                .transition(.tabContent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : Theme.quick, value: state.mainTab)
        }
        .background(AmbientBackground())
        .frame(minWidth: 640, minHeight: 440)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Clarping")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            PillPicker(items: MainTab.allCases, title: { $0.rawValue }, selection: $state.mainTab, glass: true)
                .accessibilityLabel("Section")
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Fade up from 10 pt below with a 6 pt blur clearing; used for tab content.
private struct TabReveal: ViewModifier {
    var hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? 10 : 0)
            .blur(radius: hidden ? 6 : 0)
    }
}

extension AnyTransition {
    /// Insertion: fade + rise + un-blur on the ambient animation (Theme.quick).
    /// Removal: a faster plain fade so the outgoing tab clears first.
    static var tabContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: TabReveal(hidden: true), identity: TabReveal(hidden: false)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.12))
        )
    }
}

/// Segmented control drawn as a capsule of text buttons; the selected one sits
/// on a cream highlight that slides between items (matchedGeometryEffect).
/// `glass: true` puts the capsule on Liquid Glass (window header); otherwise it
/// is a solid warm track, for controls that live inside content.
struct PillPicker<Item: Hashable>: View {
    var items: [Item]
    var title: (Item) -> String
    @Binding var selection: Item
    var glass = false
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let row = HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    guard item != selection else { return }
                    withAnimation(reduceMotion ? nil : Theme.quick) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.cardLifted)
                                    .overlay(Capsule().stroke(Theme.hairline.opacity(glass ? 0.6 : 1), lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)

        if glass, #available(macOS 26.0, *), !reduceTransparency, !Theme.forceSolid {
            row.glassEffect(.regular.tint(Theme.glassTint.opacity(0.7)).interactive(), in: Capsule())
        } else if glass {
            row.glassSurface(radius: 999)
        } else {
            row
                .background(Capsule().fill(Theme.track.opacity(0.7)))
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
        }
    }
}

// MARK: - Shared pieces

/// Serif section title over its content.
private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.system(size: 14, weight: .semibold, design: .serif))
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
        content()
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

// MARK: - Dashboard

enum Period: String, CaseIterable {
    case today = "Today", week = "This week", month = "This month", lastMonth = "Last month"

    var days: Set<String> {
        let cal = Calendar.current, now = Date()
        switch self {
        case .today: return [DayKey.of(now)]
        case .week:
            let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return Set(DayKey.days(from: start, to: now))
        case .month:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return Set(DayKey.days(from: start, to: now))
        case .lastMonth:
            let thisStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let start = cal.date(byAdding: .month, value: -1, to: thisStart)!
            return Set(DayKey.days(from: start, to: thisStart.addingTimeInterval(-1)))
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var periodBox = Box(Period.today)
    private var period: Period { periodBox.value }

    private static let columns = ["Input", "Output", "Cache read", "Cache write"]
    private static let columnWidth: CGFloat = 104

    private struct Row: Identifiable {
        var id: String
        var name: String
        var color: Color?
        var plan: String?
        var bucket: TokenBucket
    }

    private func name(for accountId: String) -> (String, Color?) {
        if let a = state.accounts.first(where: { $0.id == accountId }) { return (a.label, Color(hexString: a.colorHex)) }
        return (accountId == TokenStats.unattributed ? "Unattributed" : "Removed account", nil)
    }

    private var accountRows: [Row] {
        let days = period.days
        var rows: [Row] = []
        for (acc, _) in state.tokenStats.sumByAccount(days: days) {
            let total = state.tokenStats.sum(days: days, account: acc).values.reduce(TokenBucket(), +)
            let n = name(for: acc)
            let plan = state.accounts.first(where: { $0.id == acc })?.planName
            rows.append(Row(id: acc, name: n.0, color: n.1, plan: plan, bucket: total))
        }
        rows.sort { $0.bucket.total > $1.bucket.total }
        let all = state.tokenStats.sum(days: days)
        rows.append(Row(id: "_total", name: "Total", color: nil, plan: nil, bucket: all.values.reduce(TokenBucket(), +)))
        return rows
    }

    private var modelRows: [Row] {
        state.tokenStats.sum(days: period.days).map { fam, b in
            Row(id: fam, name: fam, color: Theme.familyColors[fam], plan: nil, bucket: b)
        }.sorted { $0.bucket.total > $1.bucket.total }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center) {
                    PillPicker(items: Period.allCases, title: { $0.rawValue }, selection: $periodBox.value)
                        .accessibilityLabel("Period")
                    Spacer()
                    if let t = state.tokenStats.lastIngest {
                        Text("Logs read \(Format.dayClock(t))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                section("Tokens by account") { tokenTable(accountRows, emphasizeLast: true) }
                section("Tokens by model") { tokenTable(modelRows, emphasizeLast: false) }
                section("Daily tokens, last 30 days") { dailyChart }
                section("Limits, last 24 hours") { limitsChart }
                section("Switch history") { switchHistory }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private func tokenTable(_ rows: [Row], emphasizeLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(emphasizeLast ? "Account" : "Model").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Self.columns, id: \.self) { Text($0).frame(width: Self.columnWidth, alignment: .trailing) }
            }
            .font(.system(size: 10.5, weight: .medium))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 6).padding(.bottom, 8)
            Hairline()
            if rows.isEmpty || (emphasizeLast && rows.count == 1 && rows[0].bucket.total == 0) {
                Text("No usage in this period")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 12)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    let total = emphasizeLast && i == rows.count - 1
                    tokenRow(r, total: total)
                    if i < rows.count - 1 && !(emphasizeLast && i == rows.count - 2) { Hairline() }
                }
            }
        }
        .card()
    }

    private func tokenRow(_ r: Row, total: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if let c = r.color {
                    Circle().fill(c).frame(width: 8, height: 8)
                } else if !total {
                    Circle().stroke(Theme.inkSecondary.opacity(0.5), lineWidth: 1).frame(width: 8, height: 8)
                }
                Text(r.name)
                    .font(.system(size: 12.5, weight: total ? .semibold : .medium))
                    .lineLimit(1)
                if let p = r.plan { PlanBadge(name: p) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array([r.bucket.input, r.bucket.output, r.bucket.cacheRead, r.bucket.cacheWrite].enumerated()), id: \.offset) { _, v in
                Text(Format.tokens(v))
                    .font(.system(size: 12, weight: total ? .semibold : .regular).monospacedDigit())
                    .frame(width: Self.columnWidth, alignment: .trailing)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 6).padding(.vertical, 9)
        .background {
            if total {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.track.opacity(0.6))
            }
        }
        .padding(.top, total ? 4 : 0)
        .accessibilityElement(children: .combine)
    }

    private var dailyChart: some View {
        let days = DayKey.days(from: Date().addingTimeInterval(-29 * 86400), to: Date())
        let data = state.tokenStats.perDay(days: days)
        return Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                BarMark(x: .value("Day", d.day), y: .value("Tokens", d.bucket.total))
                    .foregroundStyle(by: .value("Model", d.family))
                    .cornerRadius(2)
            }
        }
        .chartForegroundStyleScale(domain: Pricing.families, range: Pricing.families.map { Theme.familyColors[$0]! })
        .chartXAxis {
            AxisMarks(values: days.enumerated().filter { $0.offset % 7 == 3 }.map(\.element)) { v in
                AxisValueLabel { if let s = v.as(String.self) { Text(Self.shortDay(s)) } }
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairline)
                AxisValueLabel { if let n = v.as(Int.self) { Text(Format.tokens(n)) } }
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 12)
        .font(.system(size: 10.5))
        .frame(height: 190)
        .padding(4)
        .card()
    }

    private static let shortDayFormat: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d"); return f
    }()
    /// "2026-10-15" -> "Oct 15" (axis labels only).
    private static func shortDay(_ key: String) -> String {
        DayKey.formatter.date(from: key).map { shortDayFormat.string(from: $0) } ?? String(key.suffix(5))
    }

    private struct LimitPoint: Identifiable {
        var id: String { "\(series)-\(at.timeIntervalSince1970)" }
        var series: String
        var at: Date
        var value: Double
    }

    private var limitsChart: some View {
        let since = Date().addingTimeInterval(-86400)
        var points: [LimitPoint] = []
        if let id = state.activeId {
            for s in state.snapshots where s.accountId == id && s.at > since {
                if let f = s.fiveHour { points.append(LimitPoint(series: "5-hour", at: s.at, value: f)) }
                if let w = s.sevenDay { points.append(LimitPoint(series: "Weekly", at: s.at, value: w)) }
                for m in s.models { points.append(LimitPoint(series: m.name, at: s.at, value: m.percent)) }
            }
        }
        return Group {
            if points.count < 2 {
                Text("Limit history fills in as Clarping polls the active account.")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 6)
            } else {
                let names = seriesNames(points)
                Chart(points) { p in
                    LineMark(x: .value("Time", p.at), y: .value("Percent", p.value))
                        .foregroundStyle(by: .value("Limit", p.series))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: 0...100)
                .chartForegroundStyleScale(domain: names, range: names.map(seriesColor))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairline)
                        AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.inkSecondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairline)
                        AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%") } }
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                .chartLegend(position: .top, alignment: .leading, spacing: 12)
                .font(.system(size: 10.5))
                .frame(height: 170)
                .padding(4)
            }
        }
        .card()
    }

    private func seriesNames(_ points: [LimitPoint]) -> [String] {
        var names: [String] = []
        for p in points where !names.contains(p.series) { names.append(p.series) }
        return names
    }

    private func seriesColor(_ name: String) -> Color {
        switch name {
        case "5-hour": return Theme.clayDeep
        case "Weekly": return Color(hex: 0x5C7A99)
        default: return Theme.familyColors[name] ?? Theme.amber
        }
    }

    private var switchHistory: some View {
        let entries = Array(state.switchLog.suffix(20).reversed())
        return VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("No switches yet")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 6)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 10) {
                    Image(systemName: e.ok ? "arrow.left.arrow.right" : "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(e.ok ? Theme.inkSecondary : Theme.clayDeep)
                        .frame(width: 16)
                    Text("\(e.fromId.map { name(for: $0).0 } ?? "none") to \(name(for: e.toId).0)")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                    if let n = e.note {
                        Text(n).font(.system(size: 11)).foregroundStyle(Theme.clayDeep).lineLimit(1)
                    }
                    Spacer()
                    Text(Format.dayClock(e.at))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                if i < entries.count - 1 { Hairline() }
            }
        }
        .card()
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Linked accounts") {
                    VStack(alignment: .leading, spacing: 10) {
                        if state.accounts.isEmpty {
                            Text("No accounts linked. Use \"Add current account\" in the menu bar popover.")
                                .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .card()
                        }
                        ForEach(state.accounts) { a in AccountSettingsRow(account: a) }
                        VStack(alignment: .leading, spacing: 4) { StatusLine() }
                    }
                }
                section("Behavior") {
                    VStack(spacing: 0) {
                        settingRow("Poll usage every") {
                            HStack(spacing: 6) {
                                Text("\(state.settings.pollMinutes) min").monospacedDigit().foregroundStyle(Theme.ink)
                                Stepper("", value: $state.settings.pollMinutes, in: 1...60)
                            }
                        }
                        settingRow("Show usage text in the menu bar") { Toggle("", isOn: $state.settings.menuBarText) }
                        settingRow("Notify at 80% and 95% of a limit") { Toggle("", isOn: $state.settings.notifyThresholds) }
                        settingRow("Suggest the least-used account when the active one reaches 95%") { Toggle("", isOn: $state.settings.suggestNext) }
                        settingRow("Also switch Claude Desktop (quits and relaunches it)") { Toggle("", isOn: $state.settings.switchDesktop) }
                        settingRow("Launch at login", last: true) { Toggle("", isOn: $state.settings.launchAtLogin) }
                    }
                    .font(.system(size: 12.5)).toggleStyle(.switch).controlSize(.small).tint(Theme.clay)
                    .padding(.horizontal, 4).padding(.vertical, -4)
                    .card()
                    if let e = state.errors["_settings"] {
                        Text(e).font(.system(size: 11)).foregroundStyle(Theme.clayDeep)
                    }
                }
                section("Help") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Setup guide").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                            Text("The first-run walkthrough").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer()
                        SoftButton("Open setup guide") { WindowManager.shared.showOnboarding() }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .card()
                }
                Text("Vault: ~/Library/Application Support/Clarping (metadata, snapshots, token stats). Login secrets stay in the macOS keychain under the service \"Clarping\".")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 620 + 48, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: state.settings) { _, _ in state.saveSettings() }
    }
}

private func settingRow<C: View>(_ label: String, last: Bool = false, @ViewBuilder _ control: () -> C) -> some View {
    VStack(spacing: 0) {
        HStack(spacing: 16) {
            Text(label).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            control().labelsHidden()
        }
        .padding(.vertical, 9)
        if !last { Hairline() }
    }
}

struct AccountSettingsRow: View {
    @EnvironmentObject var state: AppState
    var account: Account
    @StateObject private var local = Box(RowLocal())

    private var isActive: Bool { account.id == state.activeId }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Label", text: $local.value.label, onCommit: { var a = account; a.label = local.value.label; state.update(a) })
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.background.opacity(0.8)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                        .frame(width: 168)
                        .accessibilityLabel("Account label")
                    if let plan = account.planName { PlanBadge(name: plan) }
                    if isActive {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.clay).frame(width: 6, height: 6)
                            Text("Active").font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Theme.clayDeep)
                        .accessibilityElement(children: .combine)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.email).font(.system(size: 12)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    Text("\(account.orgName.isEmpty ? "No org" : account.orgName) · captured \(Format.dayClock(account.lastCaptured))\(account.hasDesktopSnapshot ? " · Desktop" : "")")
                        .font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                }
                .padding(.leading, 1)
                HStack(spacing: 7) {
                    ForEach(AccountColors.palette, id: \.hex) { c in
                        let chosen = account.colorHex == c.hex
                        Circle().fill(Color(hexString: c.hex)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Theme.ink.opacity(0.75), lineWidth: chosen ? 1.5 : 0).padding(-2.5))
                            .contentShape(Circle())
                            .onTapGesture { var a = account; a.colorHex = c.hex; state.update(a) }
                            .help(c.name)
                            .accessibilityLabel("Color \(c.name)")
                            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.leading, 3).padding(.top, 2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if isActive {
                    SoftButton("Re-capture") { state.recapture(account) }
                        .disabled(state.adding)
                        .help(state.settings.switchDesktop ? "Re-reads the login; quits and relaunches Claude Desktop to copy its login" : "Re-reads the login Claude Code holds now")
                }
                if local.value.confirmRemove {
                    SoftButton("Cancel") { local.value.confirmRemove = false }
                    SoftButton("Remove", prominent: true) { state.remove(account) }
                } else {
                    SoftButton("Remove") { local.value.confirmRemove = true }
                }
            }
        }
        .padding(2)
        .card(lifted: isActive)
        .onAppear { local.value.label = account.label }
    }
}

struct RowLocal { var label = ""; var confirmRemove = false }
