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
                            Text(profile.bio).font(.subheadline)
                            Text("\(profile.followerCount) followers · \(profile.likeCount) likes")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                if let feedback = viewModel.feedback {
                    FeedbackView(feedback: feedback, retry: viewModel.retryAction, dismiss: viewModel.dismissFeedback)
                }
                if let message = viewModel.state.syncFeedback {
                    Text(message).font(.footnote).foregroundColor(.secondary)
                }
                ForEach(viewModel.state.items) { item in
                    HStack {
                        RemoteArtwork(url: item.coverURL).frame(width: 72, height: 72).cornerRadius(8)
                        Text(item.title)
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
                }
                if viewModel.state.isLoading { ProgressView() }
                if let error = viewModel.state.error {
                    Text(error.message).foregroundColor(.secondary)
                    Button("Retry loading") { viewModel.loadNextPage() }
                } else if viewModel.state.hasMore && !viewModel.state.isLoading {
                    Button("Continue Loading") { viewModel.loadNextPage() }
                }
            }
            .navigationTitle("Creator")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) { viewModel.blockCreator() } label: {
                            Label("Block", systemImage: "person.crop.circle.badge.xmark")
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Creator actions")
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
    let retry: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Text(feedback.message).font(.subheadline)
            Spacer()
            if feedback.canRetry { Button("Retry", action: retry) }
            Button(action: dismiss) { Image(systemName: "xmark.circle") }
                .accessibilityLabel("Dismiss feedback")
        }
        .padding()
        .background(Color.secondary.opacity(0.16))
        .cornerRadius(12)
    }
}
