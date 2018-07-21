import Foundation
import UIKit
import SVProgressHUD
import Crashlytics
import CoreData
import Promises
import ReadingList_Foundation

class SearchOnline: UITableViewController {

    var initialSearchString: String?
    var tableItems = [SearchResult]()

    @IBOutlet private weak var addAllButton: UIBarButtonItem!
    @IBOutlet private weak var selectModeButton: UIBarButtonItem!

    var searchController: UISearchController!
    private let feedbackGenerator = UINotificationFeedbackGenerator()
    private let emptyDatasetView = UINib.instantiate(SearchBooksEmptyDataset.self)

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.tableFooterView = UIView()
        tableView.backgroundView = emptyDatasetView
        tableView.register(UINib(BookTableViewCell.self), forCellReuseIdentifier: String(describing: BookTableViewCell.self))

        searchController = NoCancelButtonSearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.returnKeyType = .search
        searchController.searchBar.text = initialSearchString
        searchController.searchBar.delegate = self
        searchController.searchBar.autocapitalizationType = .words

        if #available(iOS 11.0, *) {
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false
        } else {
            tableView.tableHeaderView = searchController.searchBar
        }

        // If we have an entry-point search, fire it off now
        if let initialSearchString = initialSearchString {
            performSearch(searchText: initialSearchString)
        }

        monitorThemeSetting()
    }

    override func initialise(withTheme theme: Theme) {
        super.initialise(withTheme: theme)
        emptyDatasetView.initialise(fromTheme: theme)

        // Navigation controller should not be nil, but - according to very rare crash reports - it sometimes is.
        // This may be due to some as-yet unexplained memory leak of the SearchOnline view controller.
        // We want to find these cases, so trigger a crash in DEBUG build.
        if let navigationController = navigationController {
            navigationController.toolbar.barStyle = theme.barStyle
        } else {
            #if DEBUG
            fatalError("navigationController was nil")
            #endif
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Deselect any highlighted row (i.e. selected row if not in edit mode)
        if !tableView.isEditing, let selectedIndexPath = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selectedIndexPath, animated: true)
        }

        // Bring up the keyboard if not results, the toolbar if there are some results
        if tableItems.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.searchController.searchBar.becomeFirstResponder()
            }
        } else {
            navigationController!.setToolbarHidden(false, animated: true)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController!.setToolbarHidden(true, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return tableItems.isEmpty ? 0 : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? tableItems.count : 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: String(describing: BookTableViewCell.self), for: indexPath) as! BookTableViewCell
        cell.configureFrom(tableItems[indexPath.row])
        return cell
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let navigationHeaderHeight: CGFloat
        if #available(iOS 11.0, *) {
            navigationHeaderHeight = tableView.universalContentInset.top
        } else {
            navigationHeaderHeight = tableView.universalContentInset.top + searchController.searchBar.frame.height
        }
        emptyDatasetView.setTopDistance(navigationHeaderHeight + 20)
    }

    @IBAction private func cancelWasPressed(_ sender: Any) {
        searchController.isActive = false
        dismiss(animated: true, completion: nil)
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard tableView.isEditing else { return }
        if tableView.indexPathsForSelectedRows == nil || tableView.indexPathsForSelectedRows!.isEmpty {
            addAllButton.isEnabled = false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let searchResult = tableItems[indexPath.row]

        // Duplicate check
        if let existingBook = Book.get(fromContext: PersistentStoreManager.container.viewContext, googleBooksId: searchResult.id, isbn: searchResult.isbn13) {
            presentDuplicateBookAlert(book: existingBook, fromSelectedIndex: indexPath); return
        }

        // If we are in multiple selection mode (i.e. Edit mode), switch the Add All button on; otherwise, fetch and segue
        if tableView.isEditing {
           addAllButton.isEnabled = true
        } else {
            fetchAndSegue(searchResult: searchResult)
        }
    }

    func performSearch(searchText: String) {
        // Don't bother searching for empty text
        guard !searchText.isEmptyOrWhitespace else { emptyDatasetView.setEmptyDatasetReason(.noSearch); return }

        SVProgressHUD.show(withStatus: "Searching...")
        feedbackGenerator.prepare()
        GoogleBooks.search(searchText)
            .always(on: .main, SVProgressHUD.dismiss)
            .catch(on: .main) { _ in
                self.feedbackGenerator.notificationOccurred(.error)
                self.emptyDatasetView.setEmptyDatasetReason(.error)
            }
            .then(on: .main, displaySearchResults)
    }

    func displaySearchResults(_ results: [SearchResult]) {
        if results.isEmpty {
            feedbackGenerator.notificationOccurred(.warning)
            emptyDatasetView.setEmptyDatasetReason(.noResults)
        } else {
            feedbackGenerator.notificationOccurred(.success)
        }

        tableItems = results
        tableView.backgroundView = tableItems.isEmpty ? emptyDatasetView : nil
        tableView.reloadData()

        // No results should hide the toolbar. Unselecting previously selected results should disable the Add All button
        navigationController!.setToolbarHidden(tableItems.isEmpty, animated: true)
        if tableView.isEditing && tableView.indexPathsForSelectedRows?.count ?? 0 == 0 {
            addAllButton.isEnabled = false
        }
    }

    func presentDuplicateBookAlert(book: Book, fromSelectedIndex indexPath: IndexPath) {
        let alert = duplicateBookAlertController(goToExistingBook: {
            self.presentingViewController!.dismiss(animated: true) {
                appDelegate.tabBarController.simulateBookSelection(book, allowTableObscuring: true)
            }
        }, cancel: {
            self.tableView.deselectRow(at: indexPath, animated: true)
        })
        searchController.present(alert, animated: true)
    }

    func createBook(inContext context: NSManagedObjectContext, from searchResult: SearchResult) -> Promise<Book> {
        let book = Book(context: context, readState: .toRead)
        return GoogleBooks.fetch(googleBooksId: searchResult.id)
            .recover { error -> FetchResult in
                switch error {
                case GoogleError.noResult: return FetchResult(fromSearchResult: searchResult)
                default: throw error
                }
            }
            .then(on: .main) { fetchResult -> Book in
                book.populate(fromFetchResult: fetchResult)
                return book
            }
    }

    func fetchAndSegue(searchResult: SearchResult) {
        UserEngagement.logEvent(.searchOnline)
        SVProgressHUD.show(withStatus: "Loading...")
        let editContext = PersistentStoreManager.container.viewContext.childContext()

        createBook(inContext: editContext, from: searchResult)
            .always(on: .main, SVProgressHUD.dismiss)
            .catch(on: .main) { _ in
                SVProgressHUD.showError(withStatus: "An error occurred. Please try again.")
            }
            .then(on: .main) { book in
                let editPage = EditBookReadState(newUnsavedBook: book, scratchpadContext: editContext)
                self.navigationController!.pushViewController(editPage, animated: true)
            }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)
        navigationController!.setToolbarHidden(true, animated: true)
    }

    @IBAction private func changeSelectMode(_ sender: UIBarButtonItem) {
        tableView.setEditing(!tableView.isEditing, animated: true)
        selectModeButton.title = tableView.isEditing ? "Select Single" : "Select Many"
        if !tableView.isEditing {
            addAllButton.isEnabled = false
        }
    }

    @IBAction private func addAllPressed(_ sender: UIBarButtonItem) {
        guard tableView.isEditing, let selectedRows = tableView.indexPathsForSelectedRows, !selectedRows.isEmpty else { return }

        // If there is only 1 cell selected, we might as well proceed as we would in single selection mode
        guard selectedRows.count > 1 else { fetchAndSegue(searchResult: tableItems[selectedRows.first!.row]); return }

        let alert = UIAlertController(title: "Add \(selectedRows.count) books", message: "Are you sure you want to add all \(selectedRows.count) selected books? They will be added to the 'To Read' section.", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Add All", style: .default) { _ in
            self.addMultiple(selectedRows: selectedRows)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    func addMultiple(selectedRows: [IndexPath]) {
        UserEngagement.logEvent(.searchOnlineMultiple)
        SVProgressHUD.show(withStatus: "Adding...")

        // Queue up the fetches
        let editContext = PersistentStoreManager.container.viewContext.childContext()
        let bookCreations = selectedRows.map { createBook(inContext: editContext, from: tableItems[$0.row]) }

        any(bookCreations)
            .always(on: .main, SVProgressHUD.dismiss)
            .catch(on: .main) { _ in
                SVProgressHUD.showError(withStatus: "An error occurred. Please try again.")
            }
            .then(on: .main) { _ in
                editContext.saveAndLogIfErrored()
                self.searchController.isActive = false
                self.presentingViewController!.dismiss(animated: true) {
                    SVProgressHUD.showInfo(withStatus: "\(selectedRows.count) \("book".pluralising(selectedRows.count)) added")
                }
            }
    }
}

extension SearchOnline: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        performSearch(searchText: searchBar.text ?? "")
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        if searchText.isEmpty {
            displaySearchResults([SearchResult]())
        }
    }
}
