import UIKit
import WebKit

@MainActor final class FeedCell: UICollectionViewCell {
    static let reuseID = "FeedCell"
    private let holder = UIView()
    private let artworkView = UIImageView()
    private let statusView = UIView()
    private let placeholder = UILabel()
    private var artworkURL: URL?
    private var artworkRequestID: UUID?
    private var artworkTask: Task<Void, Never>?
    private var isContentHidden = false
    private let retryButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let creatorButton = UIButton(type: .system)
    private let actionsButton = UIButton(type: .system)
    private weak var attached: WKWebView?
    private(set) var itemID: SekaiID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        holder.frame = contentView.bounds
        holder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(holder)
        artworkView.frame = contentView.bounds
        artworkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.backgroundColor = .darkGray
        artworkView.accessibilityIdentifier = "feed.cover"
        contentView.addSubview(artworkView)
        statusView.backgroundColor = UIColor.gray.withAlphaComponent(0.6)
        statusView.layer.cornerRadius = 8
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.isUserInteractionEnabled = false
        placeholder.accessibilityIdentifier = "feed.contentStatus"
        placeholder.textColor = .white
        placeholder.textAlignment = .center
        placeholder.numberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("Retry content", for: .normal)
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 2
        creatorButton.tintColor = .white
        creatorButton.contentHorizontalAlignment = .leading
        actionsButton.tintColor = .white
        actionsButton.setImage(UIImage(systemName: "ellipsis.circle.fill"), for: .normal)
        actionsButton.accessibilityLabel = "Content actions"
        actionsButton.showsMenuAsPrimaryAction = true
        let textStack = UIStackView(arrangedSubviews: [titleLabel, creatorButton])
        textStack.axis = .vertical
        textStack.spacing = 10
        let row = UIStackView(arrangedSubviews: [textStack, actionsButton])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        let panel = UIView()
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(row)
        statusView.addSubview(placeholder)
        contentView.addSubview(statusView)
        contentView.addSubview(retryButton)
        contentView.addSubview(panel)
        NSLayoutConstraint.activate([
            statusView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            statusView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -40),
            placeholder.leadingAnchor.constraint(equalTo: statusView.leadingAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(equalTo: statusView.trailingAnchor, constant: -12),
            placeholder.topAnchor.constraint(equalTo: statusView.topAnchor, constant: 8),
            placeholder.bottomAnchor.constraint(equalTo: statusView.bottomAnchor, constant: -8),
            retryButton.topAnchor.constraint(equalTo: statusView.bottomAnchor, constant: 12),
            retryButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            actionsButton.widthAnchor.constraint(equalToConstant: 48),
            actionsButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: SekaiItem, pool: WebViewSlotPool, openCreator: @escaping () -> Void,
                   report: @escaping (String) -> Void, block: @escaping () -> Void) {
        if itemID != item.id || artworkURL != item.coverURL {
            detach()
            clearArtwork()
            itemID = item.id
            loadArtwork(url: item.coverURL)
        }
        isContentHidden = false
        titleLabel.text = item.title
        creatorButton.setTitle(item.creatorName, for: .normal)
        creatorButton.removeTarget(nil, action: nil, for: .allEvents)
        creatorButton.removeAction(identifiedBy: UIAction.Identifier("creator"), for: .touchUpInside)
        creatorButton.addAction(UIAction(identifier: UIAction.Identifier("creator")) { _ in openCreator() }, for: .touchUpInside)
        actionsButton.menu = UIMenu(children: [
            UIMenu(title: "Report content", children: ["Spam", "Abusive content", "Other"].map { reason in
                UIAction(title: reason) { _ in report(reason.lowercased()) }
            }),
            UIAction(title: "Block creator", attributes: .destructive) { _ in block() }
        ])
        retryButton.removeAction(identifiedBy: UIAction.Identifier("retry"), for: .touchUpInside)
        retryButton.addAction(UIAction(identifier: UIAction.Identifier("retry")) { _ in
            pool.retry(itemID: item.id)
        }, for: .touchUpInside)
        render(pool.presentation(for: item.id))
    }

    func render(_ presentation: WebViewSlotPool.Presentation?) {
        guard !isContentHidden else { return }
        guard let presentation else {
            detach()
            placeholder.text = "Settle here to load content"
            artworkView.isHidden = false
            statusView.isHidden = false
            retryButton.isHidden = true
            return
        }
        if attached !== presentation.webView {
            let phase = FeedPerformance.begin("FeedWebViewAttach", "item=\(itemID ?? "none")")
            defer { phase?.end() }
            detach()
            let webView = presentation.webView
            webView.removeFromSuperview()
            webView.frame = holder.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            holder.addSubview(webView)
            attached = webView
        }
        presentation.webView.isHidden = !presentation.isReady
        placeholder.text = presentation.error ?? "Loading content…"
        artworkView.isHidden = presentation.isReady
        statusView.isHidden = presentation.isReady
        retryButton.isHidden = presentation.isReady || presentation.error == nil
    }

    func cover() {
        isContentHidden = true
        detach()
        clearArtwork()
        artworkView.isHidden = true
        placeholder.text = "Content hidden"
        statusView.isHidden = false
        retryButton.isHidden = true
    }

    private func loadArtwork(url: URL) {
        artworkURL = url
        let requestID = UUID()
        let boundItemID = itemID
        artworkRequestID = requestID
        artworkTask = Task { [weak self] in
            let image = try? await RemoteImageLoader.fetch(url)
            guard let self, self.artworkRequestID == requestID else { return }
            self.artworkTask = nil
            guard let image, self.itemID == boundItemID, self.artworkURL == url,
                  !self.isContentHidden else { return }
            // Readiness alone controls visibility, even when artwork finishes later.
            self.artworkView.image = image
        }
    }

    private func clearArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = nil
        artworkURL = nil
        artworkView.image = nil
    }

    func detach() {
        if attached?.superview === holder {
            let phase = FeedPerformance.begin("FeedWebViewDetach", "item=\(itemID ?? "none")")
            defer { phase?.end() }
            attached?.removeFromSuperview()
        }
        attached = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        detach()
        clearArtwork()
        itemID = nil
        isContentHidden = false
        artworkView.isHidden = false
        statusView.isHidden = true
        placeholder.text = nil
        retryButton.isHidden = true
    }

    deinit { artworkTask?.cancel() }
}
