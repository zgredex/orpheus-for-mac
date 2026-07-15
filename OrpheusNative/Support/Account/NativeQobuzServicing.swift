import NativeQobuzCore

protocol NativeQobuzServicing: QobuzCatalogService, QobuzBrowsingService {}

extension QobuzAPIClient: NativeQobuzServicing {}
