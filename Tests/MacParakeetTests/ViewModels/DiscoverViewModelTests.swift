import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class DiscoverViewModelTests: XCTestCase {
    private struct StubDiscoverService: DiscoverServiceProtocol {
        let feed: DiscoverFeed

        func loadContent() async -> DiscoverFeed { feed }
        func fetchFresh() async -> DiscoverFeed? { feed }
    }

    private var emptyFeed: DiscoverFeed {
        DiscoverFeed(version: 1, items: [], featuredIndex: 0)
    }

    func testCancelDiscoverClearsLoadedFeed() async {
        let viewModel = DiscoverViewModel()
        viewModel.configure(service: StubDiscoverService(feed: emptyFeed))
        viewModel.loadCached()

        // Let the load task settle.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(viewModel.feed)

        viewModel.cancelDiscover()
        XCTAssertNil(viewModel.feed)
        XCTAssertTrue(viewModel.allItems.isEmpty)
        XCTAssertNil(viewModel.sidebarItem)
    }

    func testLoadCachedIsInertAfterCancel() async {
        let viewModel = DiscoverViewModel()
        viewModel.configure(service: StubDiscoverService(feed: emptyFeed))
        viewModel.cancelDiscover()

        // `cancelDiscover` drops the service, so a later load must not repopulate
        // the feed until `configure(service:)` runs again on re-enable.
        viewModel.loadCached()
        viewModel.refreshInBackground()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(viewModel.feed)
    }

    func testCancelDiscoverIsSafeBeforeConfigure() {
        let viewModel = DiscoverViewModel()
        viewModel.cancelDiscover()
        XCTAssertNil(viewModel.feed)
    }
}
