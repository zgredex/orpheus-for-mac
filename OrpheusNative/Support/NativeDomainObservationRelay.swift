import Combine

@MainActor
final class NativeSessionObservationRelay {
    private let onPersistenceChange: () -> Void
    private var observations = Set<AnyCancellable>()

    init(onPersistenceChange: @escaping () -> Void) {
        self.onPersistenceChange = onPersistenceChange
    }

    func observe<Object: ObservableObject>(_ object: Object) {
        object.objectWillChange.sink { [weak self] _ in
            self?.onPersistenceChange()
        }
        .store(in: &observations)
    }
}
