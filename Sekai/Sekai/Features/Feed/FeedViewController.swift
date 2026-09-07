import UIKit
import SwiftUI

@MainActor final class FeedViewController: UIViewController, UICollectionViewDelegate {
    private let viewModel: FeedViewModel
    private let pool: WebViewSlotPool
    private var collectionView: UICollectionView!
    private let webCanvas = UIView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, SekaiID>!
    private var items: [SekaiItem] = []
    private var currentID: SekaiID?
    private var settled = true
    private var displayed = false
    private var unobscured = true
    private var foreground = true
    private var snapshotRevision = 0
    private var lastSize = CGSize.zero
    private var scrollInterval: FeedPerformance.Interval?

    init(viewModel: FeedViewModel, pool: WebViewSlotPool) {
        self.viewModel = viewModel
        self.pool = pool
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        foreground = UIApplication.shared.applicationState == .active
        view.backgroundColor = .black
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .black
        collectionView.accessibilityIdentifier = "feed.list"
        collectionView.isPagingEnabled = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        collectionView.delegate = self
        collectionView.register(FeedCell.self, forCellWithReuseIdentifier: FeedCell.reuseID)
        view.addSubview(collectionView)
        webCanvas.backgroundColor = .clear
        webCanvas.clipsToBounds = true
        collectionView.insertSubview(webCanvas, at: 0)
        pool.mountWebViews(in: webCanvas)
        dataSource = UICollectionViewDiffableDataSource<Int, SekaiID>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            guard let self, let item = self.items.first(where: { $0.id == id }),
                  let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FeedCell.reuseID,
                                                               for: indexPath) as? FeedCell else { return nil }
            cell.configure(item: item, pool: self.pool,
                           openCreator: { [weak self] in self?.viewModel.openCreator(item.creatorID) },
                           report: { [weak self] in self?.viewModel.report(item.id, reason: $0) },
                           block: { [weak self] in self?.viewModel.blockCreator(item.creatorID) })
            return cell
        }
        pool.onChange = { [weak self] in self?.updateWebContent() }
        NotificationCenter.default.addObserver(self, selector: #selector(background),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(active),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard collectionView.bounds.size != lastSize else { return }
        let phase = FeedPerformance.begin("FeedLayout")
        defer { phase?.end() }
        lastSize = collectionView.bounds.size
        (collectionView.collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize = lastSize
        collectionView.collectionViewLayout.invalidateLayout()
        positionCurrent()
        collectionView.layoutIfNeeded()
        layoutWebContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        displayed = true
        updateEligibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayed = false
        finishScroll("feed disappeared")
        updateEligibility()
    }

    func setFeedDisplayed(_ value: Bool) {
        if unobscured != value { FeedPerformance.event("FeedVisibility", "displayed=\(value)") }
        if !value { finishScroll("feed obscured") }
        unobscured = value
        updateEligibility()
    }

    func apply(_ state: FeedState) {
        loadViewIfNeeded()
        let oldIDs = items.map(\.id)
        let newIDs = state.items.map(\.id)
        guard items != state.items else { return }
        if oldIDs == newIDs {
            pool.setEligibleTarget(nil)
            let changed = Set(zip(items, state.items).filter { $0.gameURL != $1.gameURL }.map { $0.0.id })
            for case let cell as FeedCell in collectionView.subviews {
                if let id = cell.itemID, changed.contains(id) { cell.cover() }
            }
            items = state.items
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(newIDs)
            dataSource.apply(snapshot, animatingDifferences: false)
            assignWindow()
            updateEligibility()
            layoutWebContent()
            return
        }
        let phase = FeedPerformance.begin("FeedSnapshot", "old=\(oldIDs.count) new=\(newIDs.count) revision=\(snapshotRevision + 1)")
        let removed = Set(oldIDs).subtracting(newIDs)
        // Include prepared cells, not only currently visible cells.
        for case let cell as FeedCell in collectionView.subviews {
            if let id = cell.itemID, removed.contains(id) { cell.cover() }
        }
        pool.setEligibleTarget(nil)
        pool.removeHiddenItems(survivingIDs: Set(newIDs))
        settled = false
        currentID = PlaybackPolicy.replacement(oldIDs: oldIDs, newIDs: newIDs, currentID: currentID)
        items = state.items
        snapshotRevision += 1
        let revision = snapshotRevision
        var snapshot = NSDiffableDataSourceSnapshot<Int, SekaiID>()
        snapshot.appendSections([0])
        snapshot.appendItems(newIDs)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, revision == self.snapshotRevision else {
                phase?.end("superseded or released")
                return
            }
            defer { phase?.end() }
            self.collectionView.layoutIfNeeded()
            self.positionCurrent()
            self.layoutWebContent()
            self.settled = !self.collectionView.isDragging && !self.collectionView.isDecelerating
            if self.settled { self.assignWindow() }
            self.updateEligibility(reason: "snapshot")
        }
    }

    private func positionCurrent() {
        guard let currentID, let index = items.firstIndex(where: { $0.id == currentID }),
              collectionView.numberOfItems(inSection: 0) > index else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * collectionView.bounds.height), animated: false)
    }

    private func assignWindow() {
        let phase = FeedPerformance.begin("FeedAssignWindow", "item=\(currentID ?? "none")")
        defer { phase?.end() }
        pool.assign(items: items, currentID: currentID)
        updateWebContent()
        if let currentID, let index = items.firstIndex(where: { $0.id == currentID }),
           index >= items.count - 3, !viewModel.state.needsContinue, viewModel.state.error == nil {
            viewModel.loadNextPage()
        }
    }

    private func updateEligibility(reason: String = "resume") {
        pool.setContentActive(foreground && displayed && unobscured)
        pool.setEligibleTarget(PlaybackPolicy.eligibleTarget(
            currentID: currentID, visibleIDs: items.map(\.id), foreground: foreground,
            displayed: displayed && unobscured, settled: settled), reason: reason)
    }

    private func settle() {
        finishScroll("settled")
        let phase = FeedPerformance.begin("FeedSettle")
        defer { phase?.end() }
        guard !items.isEmpty, collectionView.bounds.height > 0 else { return }
        let index = min(items.count - 1, max(0, Int(round(collectionView.contentOffset.y / collectionView.bounds.height))))
        currentID = items[index].id
        FeedPerformance.event("FeedCurrentItem", "index=\(index) item=\(items[index].id)")
        settled = true
        assignWindow()
        updateEligibility(reason: "settled")
    }

    private func renderVisibleCells() {
        let phase = FeedPerformance.begin("FeedRenderCells")
        defer { phase?.end() }
        for case let cell as FeedCell in collectionView.visibleCells {
            if let id = cell.itemID { cell.render(pool.presentation(for: id)) }
        }
    }

    private func updateWebContent() {
        layoutWebContent()
        renderVisibleCells()
    }

    private func layoutWebContent() {
        guard collectionView.bounds.width > 0, collectionView.bounds.height > 0 else { return }
        let contentHeight = max(collectionView.contentSize.height,
                                max(CGFloat(items.count) * collectionView.bounds.height,
                                    collectionView.bounds.height))
        webCanvas.frame = CGRect(x: 0, y: 0, width: collectionView.bounds.width, height: contentHeight)
        collectionView.sendSubviewToBack(webCanvas)
        var frames: [SekaiID: CGRect] = [:]
        for (index, item) in items.enumerated() {
            frames[item.id] = CGRect(x: 0, y: CGFloat(index) * collectionView.bounds.height,
                                     width: collectionView.bounds.width,
                                     height: collectionView.bounds.height)
        }
        let parkedFrame = CGRect(x: 0, y: contentHeight + collectionView.bounds.height,
                                 width: collectionView.bounds.width,
                                 height: collectionView.bounds.height)
        pool.positionWebViews(itemFrames: frames, parkedFrame: parkedFrame)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        finishScroll("new drag")
        scrollInterval = FeedPerformance.begin("FeedDrag", "item=\(currentID ?? "none")")
        settled = false
        updateEligibility()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        finishScroll("drag ended")
        if decelerate { scrollInterval = FeedPerformance.begin("FeedDeceleration") }
        else { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        collectionView.sendSubviewToBack(webCanvas)
        guard let cell = cell as? FeedCell, let id = cell.itemID else { return }
        cell.render(pool.presentation(for: id))
    }

    private func finishScroll(_ reason: String) {
        scrollInterval?.end(reason)
        scrollInterval = nil
    }

    @objc private func background() {
        FeedPerformance.event("FeedLifecycle", "inactive")
        finishScroll("inactive")
        foreground = false
        updateEligibility()
    }
    @objc private func active() {
        FeedPerformance.event("FeedLifecycle", "active")
        foreground = true
        updateEligibility()
    }
    @objc private func memoryWarning() {
        collectionView.isPrefetchingEnabled = false
        pool.memoryWarning()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

struct FeedContainerView: UIViewControllerRepresentable {
    let controller: FeedViewController
    let state: FeedState
    let displayed: Bool

    func makeUIViewController(context: Context) -> FeedViewController { controller }
    func updateUIViewController(_ uiViewController: FeedViewController, context: Context) {
        uiViewController.setFeedDisplayed(displayed)
        uiViewController.apply(state)
    }
}
