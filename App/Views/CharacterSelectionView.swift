import SwiftUI
import UniformTypeIdentifiers

/// 起動直後に表示するキャラクター一覧。顔写真をタップすると、記録した場所のVRMを開いて会話画面へ進む。
@available(iOS 18.0, *)
public struct CharacterSelectionView: View {
    @ObservedObject var library: VRMCharacterLibrary = .shared
    @ObservedObject var characterController: VRMCharacterController = .shared
    /// キャラクターの表示まで済んだら呼ばれる
    let onOpened: () -> Void

    /// ファイル選択の目的。ピッカーは閉じるときに表示フラグを先に false にしてから結果を返すので、
    /// 表示フラグとは別に持ち、結果を受け取るまで消さない。
    @State private var importTarget: ImportTarget = .add
    @State private var isImporterPresented = false
    @State private var failure: Failure?

    private enum ImportTarget: Equatable {
        case add
        case relink(VRMCharacterEntry)
    }

    private struct Failure: Identifiable {
        let id = UUID()
        let entry: VRMCharacterEntry?
        let message: String

        /// 同梱アバター以外は、開けなければファイルを選び直せる
        var canRelink: Bool { entry.map { !$0.isBuiltIn } ?? false }
    }

    static let vrmContentTypes: [UTType] = [
        UTType("org.vrm-consortium.vrm"),
        UTType(filenameExtension: "vrm"),
        UTType(filenameExtension: "glb"),
        .data,
        .item
    ].compactMap { $0 }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    public init(onOpened: @escaping () -> Void) {
        self.onOpened = onOpened
    }

    public var body: some View {
        ZStack {
            AppTheme.backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("キャラクターを選ぶ")
                            .font(.title2)
                            .fontWeight(.heavy)
                            .foregroundColor(AppTheme.textPrimary)
                        Text("タップすると前回のVRMファイルを開いて、すぐに会話を始められます。")
                            .font(.footnote)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    .padding(.top, 12)

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(library.entries) { entry in
                            card(for: entry)
                        }
                        addCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Self.vrmContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                switch importTarget {
                case .add:
                    run(entry: nil) { try await library.add(pickedURL: url) }
                case .relink(let entry):
                    run(entry: entry) { try await library.relink(entry, to: url) }
                }
            case .failure(let error):
                failure = Failure(entry: nil, message: "ファイル選択エラー: \(error.localizedDescription)")
            }
        }
        .alert(
            "キャラクターを開けませんでした",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { failure in
            if failure.canRelink, let entry = failure.entry {
                Button("ファイルを選び直す") { presentImporterAfterAlert(.relink(entry)) }
            } else if failure.entry == nil {
                Button("別のファイルを選ぶ") { presentImporterAfterAlert(.add) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    // MARK: - カード

    private func card(for entry: VRMCharacterEntry) -> some View {
        let isOpening = library.openingID == entry.id
        let isRecent = entry.lastOpenedAt != nil && entry.id == library.entries.first?.id
        return Button {
            run(entry: entry) { try await library.open(entry) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail(for: entry)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if isRecent {
                            Text("前回")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppTheme.primaryButtonGradient, in: Capsule())
                                .padding(8)
                        }
                    }
                    .overlay {
                        if isOpening {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                VStack(spacing: 8) {
                                    ProgressView()
                                    Text("読み込み中…")
                                        .font(.caption)
                                        .foregroundColor(AppTheme.textSecondary)
                                }
                            }
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(entry.isBuiltIn ? "同梱サンプル（作者：taiyop）" : (entry.fileName ?? "VRMファイル"))
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.85))
                    .shadow(color: AppTheme.puppyPink.opacity(0.15), radius: 10, x: 0, y: 4)
            )
        }
        .buttonStyle(.plain)
        .disabled(library.openingID != nil)
        .contextMenu {
            if library.activeID == entry.id && characterController.isLoaded {
                Button {
                    Task { await library.captureThumbnail(for: entry.id) }
                } label: {
                    Label("顔写真を撮り直す", systemImage: "camera")
                }
            }
            if !entry.isBuiltIn {
                Button {
                    presentImporter(.relink(entry))
                } label: {
                    Label("ファイルを選び直す", systemImage: "folder")
                }
                Button(role: .destructive) {
                    library.remove(entry)
                } label: {
                    Label("一覧から外す", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("\(entry.name)と話す")
    }

    @ViewBuilder
    private func thumbnail(for entry: VRMCharacterEntry) -> some View {
        if let image = library.thumbnails[entry.id] {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [AppTheme.puppySoftPink, AppTheme.puppySoftLavender],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundColor(AppTheme.puppyPink)
                    Text("開くと顔写真を保存します")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                }
            }
        }
    }

    private var addCard: some View {
        Button {
            presentImporter(.add)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(AppTheme.puppyPink)
                Text("VRMを追加")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(AppTheme.textPrimary)
                Text("ファイルアプリから選ぶ")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(AppTheme.puppyPink.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white.opacity(0.5)))
            )
        }
        .buttonStyle(.plain)
        .disabled(library.openingID != nil)
        .accessibilityLabel("VRMファイルを追加")
    }

    // MARK: - 読み込み

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        isImporterPresented = true
    }

    /// アラートが閉じきる前にピッカーを出すと表示されないことがあるので、少し待つ
    private func presentImporterAfterAlert(_ target: ImportTarget) {
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            presentImporter(target)
        }
    }

    private func run(entry: VRMCharacterEntry?, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                onOpened()
            } catch is CancellationError {
                // 別の読み込み中に押された
            } catch {
                failure = Failure(entry: entry, message: error.localizedDescription)
            }
        }
    }
}
