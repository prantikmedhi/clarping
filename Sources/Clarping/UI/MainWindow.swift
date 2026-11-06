import SwiftUI
import Charts

struct MainWindow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clarping").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
                Spacer()
                Picker("", selection: $state.mainTab) {
                    ForEach(MainTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 12)
            Divider().overlay(Theme.hairline)
            Group {
                switch state.mainTab {
                case .dashboard: DashboardView()
                case .settings: SettingsView()
                }
            }
        }
        .background(Theme.background)
        .frame(minWidth: 640, minHeight: 440)
    }
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

    private struct Row: Identifiable {
        var id: String
        var name: String
        var color: Color?
        var bucket: TokenBucket
        var cost: Double
    }

    private func name(for accountId: String) -> (String, Color?) {
        if let a = state.accounts.first(where: { $0.id == accountId }) { return (a.label, Color(hexString: a.colorHex)) }
        return (accountId == TokenStats.unattributed ? "Unattributed" : "Removed account", nil)
    }

    private var accountRows: [Row] {
        let days = period.days
        var rows: [Row] = []
        for (acc, _) in state.tokenStats.sumByAccount(days: days) {
            let fam = state.tokenStats.sum(days: days, account: acc)
            let total = fam.values.reduce(TokenBucket(), +)
            let cost = fam.reduce(0.0) { $0 + Pricing.cost(family: $1.key, $1.value) }
            let n = name(for: acc)
            rows.append(Row(id: acc, name: n.0, color: n.1, bucket: total, cost: cost))
        }
        rows.sort { $0.bucket.total > $1.bucket.total }
        let all = state.tokenStats.sum(days: days)
        rows.append(Row(id: "_total", name: "Total", color: nil, bucket: all.values.reduce(TokenBucket(), +),
                        cost: all.reduce(0.0) { $0 + Pricing.cost(family: $1.key, $1.value) }))
        return rows
    }

    private var modelRows: [Row] {
        state.tokenStats.sum(days: period.days).map { fam, b in
            Row(id: fam, name: fam, color: Theme.familyColors[fam], bucket: b, cost: Pricing.cost(family: fam, b))
        }.sorted { $0.bucket.total > $1.bucket.total }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Picker("", selection: $periodBox.value) { ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    Spacer()
                    if let t = state.tokenStats.lastIngest {
                        Text("Logs read \(Format.dayClock(t))").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                section("Tokens by account") { tokenTable(accountRows, emphasizeLast: true) }
                section("Tokens by model") { tokenTable(modelRows, emphasizeLast: false) }
                section("Daily tokens, last 30 days") { dailyChart.frame(height: 180) }
                section("Limits, last 24 hours") { limitsChart.frame(height: 160) }
                section("Switch history") { switchHistory }
                Text("Cost is an approximate API-list-price equivalent (Opus and Fable $15/$75, Sonnet $3/$15, Haiku $1/$5 per MTok; cache read 10%, cache write 125% of input). Subscriptions are not billed this way.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
            content()
        }
    }

    private func tokenTable(_ rows: [Row], emphasizeLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(["Input", "Output", "Cache read", "Cache write", "Est. cost"], id: \.self) {
                    Text($0).frame(width: 92, alignment: .trailing)
                }
            }
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().overlay(Theme.hairline)
            if rows.isEmpty {
                Text("No usage in this period").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary).padding(12)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                let last = emphasizeLast && i == rows.count - 1
                HStack {
                    HStack(spacing: 7) {
                        if let c = r.color { Circle().fill(c).frame(width: 7, height: 7) }
                        Text(r.name).font(.system(size: 12, weight: last ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach([r.bucket.input, r.bucket.output, r.bucket.cacheRead, r.bucket.cacheWrite], id: \.self) { v in
                        Text(Format.tokens(v)).frame(width: 92, alignment: .trailing)
                    }
                    Text(Format.money(r.cost)).frame(width: 92, alignment: .trailing)
                }
                .font(.system(size: 12, weight: last ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(last ? Theme.track.opacity(0.5) : .clear)
                if i < rows.count - 1 { Divider().overlay(Theme.hairline) }
            }
        }
        .card()
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
            AxisMarks(values: days.enumerated().filter { $0.offset % 7 == 0 }.map(\.element)) { v in
                AxisValueLabel { if let s = v.as(String.self) { Text(String(s.suffix(5))) } }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel { if let n = v.as(Int.self) { Text(Format.tokens(n)) } } } }
        .chartLegend(position: .top, alignment: .leading)
        .font(.system(size: 10))
        .card()
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
                    .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Time", p.at), y: .value("Percent", p.value))
                        .foregroundStyle(by: .value("Limit", p.series))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartYScale(domain: 0...100)
                .chartForegroundStyleScale(domain: seriesNames(points), range: seriesNames(points).map(seriesColor))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { v in AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel(format: .dateTime.hour().minute()) } }
                .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { _ in AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel() } }
                .chartLegend(position: .top, alignment: .leading)
                .font(.system(size: 10))
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
        VStack(alignment: .leading, spacing: 0) {
            if state.switchLog.isEmpty {
                Text("No switches yet").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary).padding(12)
            }
            ForEach(Array(state.switchLog.suffix(20).reversed().enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 8) {
                    Image(systemName: e.ok ? "arrow.left.arrow.right" : "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(e.ok ? Theme.inkSecondary : Theme.clayDeep).frame(width: 14)
                    Text("\(e.fromId.map { name(for: $0).0 } ?? "none") to \(name(for: e.toId).0)").font(.system(size: 12)).foregroundStyle(Theme.ink)
                    if let n = e.note { Text(n).font(.system(size: 11)).foregroundStyle(Theme.clayDeep).lineLimit(1) }
                    Spacer()
                    Text(Format.dayClock(e.at)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                if i < min(state.switchLog.count, 20) - 1 { Divider().overlay(Theme.hairline) }
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
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Linked accounts").font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
                    if state.accounts.isEmpty {
                        Text("No accounts linked. Use \"Add current account\" in the menu bar popover.")
                            .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary).card()
                    }
                    ForEach(state.accounts) { a in AccountSettingsRow(account: a) }
                    StatusLine()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Behavior").font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
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
                    .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                    .padding(.vertical, -4)
                    .card()
                    .frame(maxWidth: 560)
                    if let e = state.errors["_settings"] { Text(e).font(.system(size: 11)).foregroundStyle(Theme.clayDeep) }
                }
                Text("Vault: ~/Library/Application Support/Clarping (metadata, snapshots, token stats). Login secrets stay in the macOS keychain under the service \"Clarping\".")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .onChange(of: state.settings) { _, _ in state.saveSettings() }
    }
}

private func settingRow<C: View>(_ label: String, last: Bool = false, @ViewBuilder _ control: () -> C) -> some View {
    VStack(spacing: 0) {
        HStack {
            Text(label).foregroundStyle(Theme.ink)
            Spacer()
            control().labelsHidden()
        }
        .padding(.vertical, 8)
        if !last { Divider().overlay(Theme.hairline) }
    }
}

struct AccountSettingsRow: View {
    @EnvironmentObject var state: AppState
    var account: Account
    @StateObject private var local = Box(RowLocal())

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                ForEach(AccountColors.palette, id: \.hex) { c in
                    Circle().fill(Color(hexString: c.hex)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.ink, lineWidth: account.colorHex == c.hex ? 1.5 : 0).padding(-2))
                        .onTapGesture { var a = account; a.colorHex = c.hex; state.update(a) }
                        .help(c.name)
                }
            }
            TextField("Label", text: $local.value.label, onCommit: { var a = account; a.label = local.value.label; state.update(a) })
                .textFieldStyle(.roundedBorder).frame(width: 150)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.email).font(.system(size: 11)).foregroundStyle(Theme.ink)
                Text("\(account.orgName.isEmpty ? "No org" : account.orgName) · captured \(Format.dayClock(account.lastCaptured))\(account.hasDesktopSnapshot ? " · Desktop" : "")")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if account.id == state.activeId {
                Text("active").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.clayDeep)
                Button("Re-capture") { state.recapture(account) }.buttonStyle(QuietButtonStyle()).disabled(state.adding)
                    .help(state.settings.switchDesktop ? "Re-reads the login; quits and relaunches Claude Desktop to copy its login" : "Re-reads the login Claude Code holds now")
            }
            if local.value.confirmRemove {
                Button("Cancel") { local.value.confirmRemove = false }.buttonStyle(QuietButtonStyle())
                Button("Remove") { state.remove(account) }.buttonStyle(QuietButtonStyle(prominent: true))
            } else {
                Button("Remove") { local.value.confirmRemove = true }.buttonStyle(QuietButtonStyle())
            }
        }
        .card()
        .onAppear { local.value.label = account.label }
    }
}

struct RowLocal { var label = ""; var confirmRemove = false }
