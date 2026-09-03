import SwiftUI

/// 根 Tab：健康 / 行者 / 顽鹿；重复决策由 SyncSession UIKit 置顶弹窗处理。
struct RootTabView: View {
    @Environment(SyncSession.self) private var session

    var body: some View {
        TabView {
            WorkoutListView()
                .tabItem {
                    Label("健康", systemImage: "heart.fill")
                }

            ThirdPartySourceListView(sourceId: XingzheDataSource.sourceId)
                .tabItem {
                    Label("行者", systemImage: "bicycle")
                }

            ThirdPartySourceListView(sourceId: OnelapDataSource.sourceId)
                .tabItem {
                    Label("顽鹿", systemImage: "flag.checkered")
                }
        }
        .overlay(alignment: .top) {
            if session.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(session.progress.message.isEmpty ? "同步进行中…" : session.progress.message)
                        .font(.caption)
                        .lineLimit(1)
                    Button("停止") {
                        // 调用 SyncSession.cancel：从任意 Tab 打断后台同步。
                        session.cancel()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 4)
            }
        }
        .fullScreenCover(item: Binding(
            get: { session.previewPrompt },
            set: { if $0 == nil { session.resolvePreview(.skip) } }
        )) { prompt in
            SyncPreviewView(prompt: prompt) { decision in
                session.resolvePreview(decision)
            }
        }
    }
}
