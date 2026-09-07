import SwiftUI

@MainActor struct CreatorProfileView: View {
    @StateObject private var viewModel: CreatorProfileViewModel
    @Environment(\.dismiss) private var dismiss

    init(creatorID: CreatorID, factory: CreatorProfileFactory) {
        _viewModel = StateObject(wrappedValue: factory.make(creatorID: creatorID))
    }

    var body: some View {
        NavigationView {
            List {
                if let profile = viewModel.state.profile {
                    HStack(spacing: 16) {
                        RemoteArtwork(url: profile.avatar).frame(width: 72, height: 72).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 5) {
                            Text(profile.nickName).font(.headline)
                                .accessibilityIdentifier("profile.name")
                            Text(profile.bio).font(.subheadline)
                            Text("\(profile.followerCount) followers · \(profile.likeCount) likes")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                if let feedback = viewModel.feedback {
                    FeedbackView(feedback: feedback, accessibilityPrefix: "profile.feedback",
                                 retry: viewModel.retryAction, dismiss: viewModel.dismissFeedback)
                }
                if let message = viewModel.state.syncFeedback {
                    Text(message).font(.footnote).foregroundColor(.secondary)
                        .accessibilityIdentifier("profile.syncFeedback")
                }
                ForEach(viewModel.state.items) { item in
                    HStack {
                        RemoteArtwork(url: item.coverURL).frame(width: 72, height: 72).cornerRadius(8)
                        Text(item.title)
                            .accessibilityIdentifier("profile.item.\(item.id).title")
                    }
                    .onAppear {
                        if item.id == viewModel.state.items.last?.id,
                           !viewModel.state.needsContinue, viewModel.state.error == nil {
                            viewModel.loadNextPage()
                        }
                    }
                }
                if viewModel.state.items.isEmpty && !viewModel.state.isLoading && viewModel.state.error == nil {
                    Text("No visible sekais.").foregroundColor(.secondary)
                        .accessibilityIdentifier("profile.empty")
                }
                if viewModel.state.isLoading {
                    ProgressView().accessibilityIdentifier("profile.loading")
                }
                if let error = viewModel.state.error {
                    Text(error.message).foregroundColor(.secondary)
                        .accessibilityIdentifier("profile.error")
                    Button("Retry loading") { viewModel.loadNextPage() }
                        .accessibilityIdentifier("profile.retry")
                } else if viewModel.state.hasMore && !viewModel.state.isLoading {
                    Button("Continue Loading") { viewModel.loadNextPage() }
                        .accessibilityIdentifier("profile.continue")
                }
            }
            .accessibilityIdentifier("profile.list")
            .navigationTitle("Creator")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("profile.done")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) { viewModel.blockCreator() } label: {
                            Label("Block", systemImage: "person.crop.circle.badge.xmark")
                        }
                        .accessibilityIdentifier("profile.block")
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityIdentifier("profile.actions")
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { viewModel.loadInitial() }
        .onDisappear { viewModel.stop() }
    }
}

struct FeedbackView: View {
    let feedback: ActionFeedback
    let accessibilityPrefix: String
    let retry: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Text(feedback.message).font(.subheadline)
                .accessibilityIdentifier("\(accessibilityPrefix).message")
            Spacer()
            if feedback.canRetry {
                Button("Retry", action: retry)
                    .accessibilityIdentifier("\(accessibilityPrefix).retry")
            }
            Button(action: dismiss) { Image(systemName: "xmark.circle") }
                .accessibilityIdentifier("\(accessibilityPrefix).dismiss")
        }
        .padding()
        .background(Color.secondary.opacity(0.16))
        .cornerRadius(12)
    }
}
