import SwiftUI

@MainActor struct ContentView: View {
    @ObservedObject var root: AppCompositionRoot
    var body: some View {
        Group {
            if let feed = root.feed {
                FeedScreen(session: feed, profileFactory: root.profileFactory)
            } else {
                VStack(spacing: 20) {
                    if let error = root.startupError {
                        Text(error).multilineTextAlignment(.center)
                            .accessibilityIdentifier("startup.error")
                        Button("Retry startup") { startupAttempt += 1 }
                            .accessibilityIdentifier("startup.retry")
                    } else {
                        ProgressView("Restoring hidden content…")
                            .accessibilityIdentifier("startup.loading")
                    }
                }.padding()
            }
        }
        .task(id: startupAttempt) { await root.start() }
    }
    @State private var startupAttempt = 0
}

@MainActor private struct FeedScreen: View {
    @ObservedObject private var viewModel: FeedViewModel
    private let session: FeedSession
    private let profileFactory: CreatorProfileFactory

    init(session: FeedSession, profileFactory: CreatorProfileFactory) {
        self.session = session
        self.profileFactory = profileFactory
        viewModel = session.viewModel
    }

    var body: some View {
        NavigationView {
            ZStack {
                FeedContainerView(controller: session.controller, state: viewModel.state,
                                  displayed: viewModel.selectedCreatorID == nil)
                if viewModel.state.items.isEmpty {
                    VStack(spacing: 16) {
                        Text(viewModel.state.isLoading ? "Loading sekais…" : "No visible sekais")
                            .foregroundColor(.white)
                            .accessibilityIdentifier(viewModel.state.isLoading ? "feed.loadingMessage" : "feed.empty")
                        if !viewModel.state.isLoading && viewModel.state.hasMore {
                            Button("Continue Loading") { viewModel.loadNextPage() }
                                .accessibilityIdentifier("feed.continue")
                        }
                    }
                }
                VStack {
                    if let feedback = viewModel.feedback {
                        FeedbackView(feedback: feedback, accessibilityPrefix: "feed.feedback",
                                     retry: viewModel.retryAction, dismiss: viewModel.dismissFeedback)
                            .background(.regularMaterial).cornerRadius(12).padding(.horizontal)
                    }
                    if let message = viewModel.state.syncFeedback {
                        Text(message).font(.footnote).padding(10).background(.regularMaterial).cornerRadius(8)
                            .accessibilityIdentifier("feed.syncFeedback")
                    }
                    if let error = viewModel.state.error {
                        HStack {
                            Text(error.message).font(.footnote)
                                .accessibilityIdentifier("feed.error")
                            Button("Retry") { viewModel.loadNextPage() }
                                .accessibilityIdentifier("feed.retry")
                        }.padding().background(.regularMaterial)
                    } else if viewModel.state.needsContinue && !viewModel.state.items.isEmpty {
                        Button("Continue Loading") { viewModel.loadNextPage() }
                            .accessibilityIdentifier("feed.continue")
                            .padding().background(.regularMaterial)
                    }
                    Spacer()
                    if viewModel.state.isLoading {
                        ProgressView().padding().background(.regularMaterial).cornerRadius(8)
                            .accessibilityIdentifier("feed.loading")
                    }
                }
            }
            .navigationTitle("Sekai")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { viewModel.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityIdentifier("feed.refresh")
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { if viewModel.state.items.isEmpty { viewModel.loadNextPage() } }
        .sheet(isPresented: Binding(
            get: { viewModel.selectedCreatorID != nil },
            set: { if !$0 { viewModel.selectedCreatorID = nil } })) {
                if let id = viewModel.selectedCreatorID {
                    CreatorProfileView(creatorID: id, factory: profileFactory)
                }
            }
    }
}
