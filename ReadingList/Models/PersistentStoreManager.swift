import CoreData
import CoreSpotlight

class PersistentStoreManager {

    static var container: NSPersistentContainer!

    static let storeName = "books"
    static var storeFileName: String { return "\(storeName).sqlite" }
    static var storeLocation: URL { return URL.applicationSupport.appendingPathComponent(storeFileName) }

    /**
     Creates the NSPersistentContainer, migrating if necessary.
    */
    static func initalisePersistentStore(completion: @escaping () -> Void) throws {
        if container != nil {
            logger.info("Reinitialising persistent container")
        }

        // Register our custom transformer for Author tranformable attributes
        AuthorTransformer.register()

        // Set up the container describing a manually migrated store with persistent history enabled.
        container = NSPersistentContainer(name: storeName)
        let description = NSPersistentStoreDescription(url: storeLocation)
        description.shouldInferMappingModelAutomatically = false
        description.shouldMigrateStoreAutomatically = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        container.persistentStoreDescriptions = [description]

        // Migrate the store to the latest version if necessary and then initialise
        try container.migrateAndLoad(BooksModelVersion.self) {
            self.container.viewContext.name = "ViewContext"
            self.container.viewContext.automaticallyMergesChangesFromParent = true
            self.container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
            try! self.container.viewContext.setQueryGenerationFrom(.current)
            completion()
        }
    }

    /**
     If a store exists in the Documents directory, copies it to the Application Support directory and destroys
     the old store.
    */
    static func moveStoreFromLegacyLocationIfNecessary() {
        let legacyStoreLocation = URL.documents.appendingPathComponent(storeFileName)
        if FileManager.default.fileExists(atPath: legacyStoreLocation.path) && !FileManager.default.fileExists(atPath: storeLocation.path) {
            logger.info("Store located in Documents directory; migrating to Application Support directory")
            let tempStoreCoordinator = NSPersistentStoreCoordinator()
            try! tempStoreCoordinator.replacePersistentStore(
                at: storeLocation,
                destinationOptions: nil,
                withPersistentStoreFrom: legacyStoreLocation,
                sourceOptions: nil,
                ofType: NSSQLiteStoreType)

            // Delete the old store
            tempStoreCoordinator.destroyAndDeleteStore(at: legacyStoreLocation)
        }
    }
}
