import Foundation

public struct SubjectAsyncIterator<Element: Sendable>: AsyncIteratorProtocol, Sendable {

    private var node: NodeSubject<Element>?

    init(_ node: NodeSubject<Element>) {
        self.node = node
    }

    public mutating func next() async -> Element? {
        guard let node else {
            return nil
        }

        await node.producer.wait()

        self.node = node.nextDataSource.next

        switch node.stateDataSource.state {
        case .produced(let element):
            return element
        case .waiting:
            return nil
        }
    }
}
