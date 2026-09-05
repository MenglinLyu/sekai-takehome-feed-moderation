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
                        Button("Retry startup") { startupAttempt += 1 }
                    } else { ProgressView("Restoring hidden content…") }
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
                        if !viewModel.state.isLoading && viewModel.state.hasMore {
                            Button("Continue Loading") { viewModel.loadNextPage() }
                        }
                    }
                }
                VStack {
                    if let feedback = viewModel.feedback {
                        FeedbackView(feedback: feedback, retry: viewModel.retryAction, dismiss: viewModel.dismissFeedback)
                            .background(.regularMaterial).cornerRadius(12).padding(.horizontal)
                    }
                    if let message = viewModel.state.syncFeedback {
                        Text(message).font(.footnote).padding(10).background(.regularMaterial).cornerRadius(8)
                    }
                    if let error = viewModel.state.error {
                        HStack {
                            Text(error.message).font(.footnote)
                            Button("Retry") { viewModel.loadNextPage() }
                        }.padding().background(.regularMaterial)
                    } else if viewModel.state.needsContinue && !viewModel.state.items.isEmpty {
                        Button("Continue Loading") { viewModel.loadNextPage() }
                            .padding().background(.regularMaterial)
                    }
                    Spacer()
                    if viewModel.state.isLoading { ProgressView().padding().background(.regularMaterial).cornerRadius(8) }
                }
            }
            .navigationTitle("Sekai")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { viewModel.refresh() } label: { Image(systemName: "arrow.clockwise") } }
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
