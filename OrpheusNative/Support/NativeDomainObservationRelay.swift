import Combine

@MainActor
final class NativeDomainObservationRelay {
    private let onChange: () -> Void
    private let onPersistenceChange: () -> Void
    private var observations = Set<AnyCancellable>()

    init(onChange: @escaping () -> Void, onPersistenceChange: @escaping () -> Void) {
        self.onChange = onChange
        self.onPersistenceChange = onPersistenceChange
    }

    func observe<Object: ObservableObject>(_ object: Object, persistsSession: Bool = false) {
        object.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            onChange()
            if persistsSession { onPersistenceChange() }
        }
        .store(in: &observations)
    }
}
