import CoreLocation
import SwiftUI

/// 目的地/起点检索：联想 → 正式检索 → 结果/空/失败（NAV-07/08/10）
struct SearchView: View {
    @ObservedObject var model: NavAppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().overlay(NavTheme.line)
            content
        }
        .background(NavTheme.bg)
        .onAppear {
            focused = true
            model.updateSuggestions(model.searchText)
        }
    }

    // MARK: - 顶部输入

    private var searchHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    close()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NavTheme.ink)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NavTheme.inkMute)
                    TextField(model.searchTarget == .origin ? "搜索起点" : "搜索目的地",
                              text: $model.searchText)
                        .font(.system(size: 16))
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { submit() }
                        .onChange(of: model.searchText) { text in
                            // 清空回历史/空输入态，不残留旧关键词结果（NAV-07）
                            if text.isEmpty {
                                model.clearSearchDraft()
                            } else {
                                model.hasSubmitted = false
                                model.searchResults = []
                                model.searchFailure = nil
                                model.updateSuggestions(text)
                            }
                        }
                    if !model.searchText.isEmpty {
                        Button {
                            model.clearSearchDraft()
                            focused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(NavTheme.inkMute)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空输入")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(NavTheme.line, lineWidth: 1))
            }
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .bold))
                Text("搜索范围：\(model.searchScope.label)")
                    .font(.system(size: 12, weight: .medium))
                if model.searchTarget == .destination {
                    Spacer()
                    Text("会员功能")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NavTheme.accentDeep)
                }
            }
            .foregroundStyle(NavTheme.inkMute)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .padding(.top, 2)
        .background(NavTheme.panel)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if model.hasSubmitted {
            submittedContent
        } else if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            suggestionContent
        } else {
            historyContent
        }
    }

    private var submittedContent: some View {
        ScrollView {
            if model.isSearching {
                NavLoadingRow(text: "正在查找地点…")
            } else if let failure = model.searchFailure {
                NavFailureView(failure: failure) { action in
                    switch action {
                    case .retry:
                        submit()
                    case .openSettings:
                        model.location.openAppSettings()
                    case .retryLocation:
                        Task { await model.locate() }
                    default:
                        break
                    }
                }
            } else if model.searchResults.isEmpty {
                NavEmptyView(title: "没有找到匹配地点",
                             detail: "可修改关键词或搜索范围后重试",
                             actionTitle: "修改关键词") {
                    model.hasSubmitted = false
                    focused = true
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.searchResults) { place in
                        PlaceRow(place: place, distance: distance(to: place)) {
                            model.confirm(place)
                        }
                        Divider().overlay(NavTheme.line).padding(.leading, 16)
                    }
                }
            }
        }
    }

    private var suggestionContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // 即使没有联想候选，也允许提交完整关键词（NAV-07）
                Button {
                    submit()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(NavTheme.accent)
                        Text("搜索“\(model.searchText)”")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(NavTheme.ink)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if model.isSuggesting && model.suggestions.isEmpty {
                    NavLoadingRow(text: "正在联想…")
                }
                ForEach(model.suggestions) { suggestion in
                    Button {
                        Task { await model.selectSuggestion(suggestion) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 13))
                                .foregroundStyle(NavTheme.inkMute)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(suggestion.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(NavTheme.ink)
                                    .lineLimit(1)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.system(size: 13))
                                        .foregroundStyle(NavTheme.inkMute)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(NavTheme.line).padding(.leading, 16)
                }
            }
        }
    }

    private var historyContent: some View {
        ScrollView {
            if model.stores.history.isEmpty {
                NavEmptyView(title: "还没有搜索记录",
                             detail: "输入名称或地址开始查找",
                             actionTitle: nil, onAction: nil)
            } else {
                HStack {
                    Text("最近搜索")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NavTheme.inkMute)
                    Spacer()
                    Button("清空") {
                        model.stores.clearHistory()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NavTheme.accentDeep)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                LazyVStack(spacing: 0) {
                    ForEach(model.stores.history) { entry in
                        PlaceRow(place: entry.place, distance: distance(to: entry.place)) {
                            // 历史复用按当前范围重新核验，不自动开始导航（NAV-10）
                            model.confirm(entry.place)
                        }
                        Divider().overlay(NavTheme.line).padding(.leading, 16)
                    }
                }
            }
        }
    }

    // MARK: - 动作

    private func submit() {
        focused = false
        Task { await model.submitSearch() }
    }

    private func close() {
        focused = false
        model.clearSearchDraft()
        model.flow = model.planSource == .nearby ? .plan : .home
    }

    private func distance(to place: Place) -> Double? {
        guard let snap = model.location.snapshot else { return nil }
        return Geo.distance(snap.place.gcj02Coordinate, place.gcj02Coordinate)
    }
}
