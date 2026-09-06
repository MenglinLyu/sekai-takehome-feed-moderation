import UIKit
import WebKit

@MainActor final class FeedCell: UICollectionViewCell {
    static let reuseID = "FeedCell"
    private let holder = UIView()
    private let placeholder = UILabel()
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
        contentView.addSubview(placeholder)
        contentView.addSubview(retryButton)
        contentView.addSubview(panel)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -40),
            retryButton.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 12),
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
        if itemID != item.id { detach() }
        itemID = item.id
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
        guard let presentation else {
            detach()
            placeholder.text = "Settle here to load content"
            placeholder.isHidden = false
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
        placeholder.isHidden = presentation.isReady
        retryButton.isHidden = presentation.error == nil
    }

    func cover() {
        detach()
        placeholder.text = "Content hidden"
        placeholder.isHidden = false
        retryButton.isHidden = true
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
        itemID = nil
    }
}
