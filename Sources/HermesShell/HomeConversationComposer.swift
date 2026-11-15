import SwiftUI

/// Empty-chat composer. Reuses the *same* UIKit text input, font/height
/// measurement and send-key policy as ChatComposer. It does NOT own a
/// NativeChatModel: the first chat POST belongs to the new session page only.
struct HomeConversationComposer: View {
    @Binding var text: String
    @Binding var focused: Bool
    let isCurrentScope: () -> Bool
    let draftStore: ChatDraftStore
    let modelLabel: String
    let creating: Bool
    let needsSetup: Bool
    let onSubmit: () -> Void
    let onChooseModel: () -> Void
    let onAttach: () -> Void

    @AppStorage("chatReturnSends") private var returnSends = true
    @State private var composing = false
    @State private var storageWarning = false

    private var canSubmit: Bool {
        HomeTurnPolicy.canSubmit(text: text, creating: creating, needsSetup: needsSetup)
            && !composing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(spacing: 0) {
                ChatDraftEditor(text: $text, focused: $focused,
                                editable: !creating && !needsSetup,
                                returnSends: returnSends, canSubmit: canSubmit,
                                onSubmit: submit, onComposition: { composing = $0 })
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                    .padding(.horizontal, 15)
                    .padding(.top, 7)
                    .padding(.bottom, 1)

                HStack(spacing: 4) {
                    Button(action: onAttach) {
                        Image(systemName: "plus")
                            .font(.body.weight(.medium))
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(.primary)
                    .disabled(creating || needsSetup)
                    .accessibilityLabel("添加附件")

                    Spacer(minLength: 8)
                    Button(action: onChooseModel) {
                        HStack(spacing: 4) {
                            Text(modelLabel).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 148, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .disabled(creating || needsSetup)
                    .accessibilityLabel("选择首条消息的模型，当前\(modelLabel)")

                    Button(action: submit) {
                        Group {
                            if creating {
                                ProgressView().tint(AppTheme.onAction)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.headline.weight(.semibold))
                            }
                        }
                        .frame(width: 34, height: 34)
                        .foregroundStyle(canSubmit ? AppTheme.onAction : Color.secondary)
                        .background(canSubmit || creating ? AppTheme.action : AppTheme.softFill,
                                    in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .disabled(!canSubmit)
                    .accessibilityLabel(creating ? "正在创建会话" : "发送首条消息")
                }
                .padding(.leading, 6)
                .padding(.trailing, 7)
                .padding(.bottom, 3)
            }
            .background(AppTheme.surface,
                        in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .strokeBorder(AppTheme.hairline.opacity(0.6), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }

            if storageWarning {
                Text("首页草稿暂时无法保存到设备；离开前请复制内容。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.warning)
                    .padding(.horizontal, 12)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 12)
        .task(id: text) {
            // The onDisappear save covers immediate navigation; this debounce
            // avoids a protected-file rewrite on every input keystroke.
            do { try await Task.sleep(nanoseconds: 450_000_000) }
            catch { return }
            guard !Task.isCancelled, isCurrentScope() else { return }
            storageWarning = !draftStore.save(text).succeeded
        }
        .onDisappear {
            // The root explicitly flushes the departing store on host change.
            // An old view must never write the NEW host's bound text to its
            // captured old file store when SwiftUI unmounts it.
            guard isCurrentScope() else { return }
            storageWarning = !draftStore.save(text).succeeded
        }
        .onChange(of: focused) { _, value in
            if !value && isCurrentScope() {
                storageWarning = !draftStore.save(text).succeeded
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focused = false
        onSubmit()
    }
}
