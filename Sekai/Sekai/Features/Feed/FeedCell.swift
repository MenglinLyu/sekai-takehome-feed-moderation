import UIKit

@MainActor final class FeedCell: UICollectionViewCell {
    static let reuseID = "FeedCell"
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
    private let controlsPanel = UIView()
    private var isShowingLiveWebContent = false
    private(set) var itemID: SekaiID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
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
        actionsButton.showsMenuAsPrimaryAction = true
        let textStack = UIStackView(arrangedSubviews: [titleLabel, creatorButton])
        textStack.axis = .vertical
        textStack.spacing = 10
        let row = UIStackView(arrangedSubviews: [textStack, actionsButton])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        controlsPanel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        controlsPanel.translatesAutoresizingMaskIntoConstraints = false
        controlsPanel.addSubview(row)
        statusView.addSubview(placeholder)
        contentView.addSubview(statusView)
        contentView.addSubview(retryButton)
        contentView.addSubview(controlsPanel)
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
            controlsPanel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controlsPanel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controlsPanel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: controlsPanel.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: controlsPanel.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: controlsPanel.topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: controlsPanel.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            actionsButton.widthAnchor.constraint(equalToConstant: 48),
            actionsButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: SekaiItem, pool: WebViewSlotPool, openCreator: @escaping () -> Void,
                   report: @escaping (String) -> Void, block: @escaping () -> Void) {
        if itemID != item.id || artworkURL != item.coverURL {
            clearArtwork()
            itemID = item.id
            loadArtwork(url: item.coverURL)
        }
        isContentHidden = false
        let accessibilityPrefix = "feed.item.\(item.id)"
        accessibilityIdentifier = accessibilityPrefix
        titleLabel.accessibilityIdentifier = "\(accessibilityPrefix).title"
        creatorButton.accessibilityIdentifier = "\(accessibilityPrefix).creator"
        actionsButton.accessibilityIdentifier = "\(accessibilityPrefix).actions"
        placeholder.accessibilityIdentifier = "\(accessibilityPrefix).status"
        retryButton.accessibilityIdentifier = "\(accessibilityPrefix).retry"
        titleLabel.text = item.title
        creatorButton.setTitle(item.creatorName, for: .normal)
        creatorButton.removeTarget(nil, action: nil, for: .allEvents)
        creatorButton.removeAction(identifiedBy: UIAction.Identifier("creator"), for: .touchUpInside)
        creatorButton.addAction(UIAction(identifier: UIAction.Identifier("creator")) { _ in openCreator() }, for: .touchUpInside)
        let reportReasons = [("spam", "Spam"), ("abusive", "Abusive content"), ("other", "Other")]
        let reportMenu = UIMenu(title: "Report content", children: reportReasons.map { key, reason in
            let action = UIAction(title: reason) { _ in report(reason.lowercased()) }
            action.accessibilityIdentifier = "\(accessibilityPrefix).report.\(key)"
            return action
        })
        reportMenu.accessibilityIdentifier = "\(accessibilityPrefix).report"
        let blockAction = UIAction(title: "Block creator", attributes: .destructive) { _ in block() }
        blockAction.accessibilityIdentifier = "\(accessibilityPrefix).blockCreator"
        actionsButton.menu = UIMenu(children: [reportMenu, blockAction])
        retryButton.removeAction(identifiedBy: UIAction.Identifier("retry"), for: .touchUpInside)
        retryButton.addAction(UIAction(identifier: UIAction.Identifier("retry")) { _ in
            pool.retry(itemID: item.id)
        }, for: .touchUpInside)
        render(pool.presentation(for: item.id))
    }

    func render(_ presentation: WebViewSlotPool.Presentation?) {
        guard !isContentHidden else { return }
        guard let presentation else {
            isShowingLiveWebContent = false
            contentView.backgroundColor = .black
            placeholder.text = "Settle here to load content"
            artworkView.isHidden = false
            statusView.isHidden = false
            retryButton.isHidden = true
            return
        }
        isShowingLiveWebContent = presentation.isReady
        contentView.backgroundColor = presentation.isReady ? .clear : .black
        placeholder.text = presentation.error ?? "Loading content…"
        artworkView.isHidden = presentation.isReady
        statusView.isHidden = presentation.isReady
        retryButton.isHidden = presentation.isReady || presentation.error == nil
    }

    func cover() {
        isContentHidden = true
        isShowingLiveWebContent = false
        contentView.backgroundColor = .black
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

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard isShowingLiveWebContent else { return hit }
        let panelPoint = controlsPanel.convert(point, from: self)
        if controlsPanel.point(inside: panelPoint, with: event) { return hit }
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearArtwork()
        itemID = nil
        accessibilityIdentifier = nil
        titleLabel.accessibilityIdentifier = nil
        creatorButton.accessibilityIdentifier = nil
        actionsButton.accessibilityIdentifier = nil
        placeholder.accessibilityIdentifier = nil
        retryButton.accessibilityIdentifier = nil
        actionsButton.menu = nil
        isContentHidden = false
        isShowingLiveWebContent = false
        contentView.backgroundColor = .black
        artworkView.isHidden = false
        statusView.isHidden = true
        placeholder.text = nil
        retryButton.isHidden = true
    }

    deinit { artworkTask?.cancel() }
}
