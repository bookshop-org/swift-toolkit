//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit

enum ScrollLocation: Equatable {
    case start
    case end
    case locator(Locator)

    init(_ locator: Locator?) {
        self = locator.map { .locator($0) }
        ?? .start
    }

    var isStart: Bool {
        switch self {
        case .start:
            return true
        case let .locator(locator) where locator.locations.progression ?? 0 == 0:
            return true
        default:
            return false
        }
    }
}

protocol ScrollView {
    /// Moves the page to the given internal location.
    func go(to location: PageLocation) async
}

@available(iOS 14.0, *)
protocol ContinuousScrollViewDelegate: AnyObject {
    /// Creates the page view for the page at given index.
    func continuousScrollViewController(_ continuousScrollViewController: ContinuousScrollViewController, pageViewAtIndex index: Int) -> (UIView & PageView)?

    /// Called when the page views were updated.
    func continuousScrollViewControllerDidUpdateViews(_ continuousScrollViewController: ContinuousScrollViewController)

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at given index.
    func continuousScrollViewController(_ continuousScrollViewControllerController: ContinuousScrollViewController, positionCountAtIndex index: Int) -> Int
}

@available(iOS 14.0, *)
final class ContinuousScrollViewController: UIViewController, Loggable {
    enum Section {
        case main
    }

    weak var delegate: ContinuousScrollViewDelegate?

    private var spreads: [EPUBSpread] = []

    /// Total number of page views to be paginated.
    private(set) var pageCount: Int = 0

    /// Index of the page currently being displayed.
    private(set) var currentItemIndex = -1

    /// Direction for the reading progression.
    private(set) var readingProgression: ReadingProgression = .ltr

    private var itemHeights: [CGFloat] = []

    private let defaultHeight = UIScreen.main.bounds.height

    private var displayLink: CADisplayLink?
    private var isScrolling = false

    private var dataSource: UICollectionViewDiffableDataSource<Section, EPUBSpread>!

    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: makeLayout()
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.isPrefetchingEnabled = true
        collectionView.backgroundColor = .systemBackground
        collectionView.contentInsetAdjustmentBehavior = .always
        return collectionView
    }()

    init() {
        super.init(nibName: nil, bundle: nil)

        // Adds an empty view before the scroll view to have a consistent behavior on all iOS
        // versions, regarding to the content inset adjustements. Even if
        // `automaticallyAdjustsScrollViewInsets` is not set to false on the navigator's parent
        // view controller, the scroll view insets won't be adjusted if the scroll view is not the
        // first child in the subviews hierarchy.
        //insertSubview(UIView(frame: .zero), at: 0)
        // Prevents the content from jumping down when the status bar is toggled
        //scrollView.contentInsetAdjustmentBehavior = .never
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureViewHierarchy()
        configureDataSource()

        collectionView.backgroundColor = .clear
        view.backgroundColor = .clear

        //itemHeights = Array(repeating: defaultHeight, count: book.chapters.count)
    }

    private func configureViewHierarchy() {
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            view.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        ])
    }

    private func makeLayout() -> UICollectionViewLayout {
        let layoutSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(UIScreen.main.bounds.height)
        )
        let item = NSCollectionLayoutItem(layoutSize: layoutSize)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: layoutSize,
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 10,
            leading: 10,
            bottom: 10,
            trailing: 10
        )
        section.interGroupSpacing = 10

        let config = UICollectionViewCompositionalLayoutConfiguration()
        config.scrollDirection = .vertical

        return UICollectionViewCompositionalLayout(
            section: section,
            configuration: config
        )
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<ContinuousScrollCell, EPUBSpread> {
            [weak self] (cell, indexPath, spread) in

            guard let self else { return }

            cell.configure(with: spread, cachedHeight: defaultHeight)
        }

        dataSource = UICollectionViewDiffableDataSource<Section, EPUBSpread>(collectionView: collectionView) {
            (collectionView: UICollectionView, indexPath: IndexPath, item: EPUBSpread) -> UICollectionViewCell? in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }

        updateSnapshot(animated: true)

        updateCurrentItemIndex(0)
    }

    private func updateSnapshot(animated: Bool) {
        var fullSnapshot = NSDiffableDataSourceSnapshot<Section, EPUBSpread>()
        fullSnapshot.appendSections([.main])
        fullSnapshot.appendItems(spreads)

        dataSource.apply(fullSnapshot, animatingDifferences: animated)
    }

    private func scrollToSelectedItem(offsetBy offset: Int) {
        guard currentItemIndex != -1 else {
            return
        }

        let targetItem = currentItemIndex + offset
        scrollToItem(at: targetItem, animated: true)
    }

    private func scrollToItem(at item: Int, animated: Bool) {
        guard let topIndexPath = collectionView.indexPathsForVisibleItems.first else { return }

        let upperBound = collectionView.numberOfItems(inSection: topIndexPath.section)
        guard 0..<upperBound ~= item else { return }

        let targetIndexPath = IndexPath(item: item, section: topIndexPath.section)
        collectionView.scrollToItem(at: targetIndexPath, at: .top, animated: animated)
        collectionView.layoutIfNeeded()

        updateCurrentItemIndex(item)
    }

    /// Reloads the pagination with the given total number of pages and current index.
    ///
    /// - Parameters:
    ///   - index: Index of the page to be displayed after reloading the pagination.
    ///   - location: Location to be displayed in the page.
    ///   - pageCount: Total number of pages in the pagination view.
    ///   - readingProgression: Direction of reading progression.
    //    func reloadAtIndex(_ index: Int, location: PageLocation, pageCount: Int, readingProgression: ReadingProgression) async {
    //        precondition(pageCount >= 1)
    //        precondition(0 ..< pageCount ~= index)
    //
    //        self.pageCount = pageCount
    //        self.readingProgression = readingProgression
    //
    //        for (_, view) in loadedViews {
    //            view.removeFromSuperview()
    //        }
    //        loadedViews.removeAll()
    //        loadingIndexQueue.removeAll()
    //
    //        await setCurrentIndex(index, location: location)
    //    }

    //    private enum PageIndexDirection: Int {
    //        case forward = 1
    //        case backward = -1
    //    }

    // MARK: - Navigation

    /// Go to the page view with given index.
    ///
    /// - Parameters:
    ///   - index: The index to move to.
    ///   - location: The location to move the future current page view to.
    /// - Returns: Whether the move is possible.
    //    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
    //        guard 0 ..< pageCount ~= index else {
    //            return false
    //        }
    //
    //        if currentIndex == index {
    //            await scrollToView(at: index, location: location)
    //        } else {
    //            await fadeToView(at: index, location: location, animated: options.animated)
    //        }
    //        return true
    //    }

    //    private func fadeToView(at index: Int, location: PageLocation, animated: Bool) async {
    //        func fade(to alpha: CGFloat) async {
    //            if animated {
    //                await withCheckedContinuation { continuation in
    //                    UIView.animate(withDuration: 0.15, animations: {
    //                        self.view.alpha = alpha
    //                    }) { _ in
    //                        continuation.resume()
    //                    }
    //                }
    //            } else {
    //                self.view.alpha = alpha
    //            }
    //        }
    //
    //        await fade(to: 0)
    //        //await scrollToView(at: index, location: location)
    //        await fade(to: 1)
    //    }

    //    private func scrollToView(at index: Int, location: PageLocation) async {
    //        guard currentIndex != index else {
    //            if let view = currentView {
    //                await view.go(to: location)
    //            }
    //            return
    //        }
    //
    //        scrollView.isScrollEnabled = isScrollEnabled
    //        await setCurrentIndex(index, location: location)
    //
    //        scrollView.scrollRectToVisible(CGRect(
    //            origin: CGPoint(
    //                x: xOffsetForIndex(index),
    //                y: scrollView.contentOffset.y
    //            ),
    //            size: scrollView.frame.size
    //        ), animated: false)
    //    }

    private func updateCurrentItemIndex(_ item: Int) {
        guard currentItemIndex != item else { return }
        currentItemIndex = item
    }

    private func updateFocusedCell() {
        let visibleRect = CGRect(
            origin: CGPoint(
                x: collectionView.contentOffset.x,
                y: collectionView.contentOffset.y + collectionView.contentInset.top
            ),
            size: collectionView.bounds.size
        )
        let visiblePoint = CGPoint(
            x: visibleRect.midX,
            y: visibleRect.minY + 20
        )

        if let indexPath = collectionView.indexPathForItem(at: visiblePoint),
           currentItemIndex != indexPath.item {
            updateCurrentItemIndex(indexPath.item)
        }
    }

    private func startDisplayLink() {
        stopDisplayLink()

        displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLinkUpdate))
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)
        } else {
            displayLink?.preferredFramesPerSecond = 30
        }
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleDisplayLinkUpdate() {
        guard isScrolling else {
            stopDisplayLink()
            return
        }

        updateFocusedCell()
    }
}

@available(iOS 14.0, *)
extension ContinuousScrollViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? ContinuousScrollCell else { return }

        let cachedHeight = itemHeights[indexPath.item]
        cell.applyCachedHeight(cachedHeight)
        cell.loadContentIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isScrolling = true
        startDisplayLink()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            isScrolling = false
            stopDisplayLink()
            updateFocusedCell()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isScrolling = false
        stopDisplayLink()
        updateFocusedCell()
    }
}
