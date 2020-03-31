//
//  Created by David Hoerl on 3/24/20.
//  Copyright © 2020 David Hoerl. All rights reserved.
//

import Foundation
import Combine

enum SPErrors: Error {
	case inputStringWasEmpty
}

struct StringPublisher: Publisher {
	typealias Output = [Character]
	typealias Failure = Error

	private let data: [Character]

	init(string: String) {
		self.data = string.map({$0})
	}

	func receive<S>(subscriber: S) where
		S: Subscriber,
		S.Failure == Self.Failure,
		S.Input == Self.Output
	{
		let subscription = StringPublisherSubscription(subscriber: subscriber, data: data)
		subscriber.receive(subscription: subscription)
	}

	final class StringPublisherSubscription<S>: Subscription where
		S: Subscriber,
		S.Input == [Character],
		S.Failure == Error
	{
		private var subscriber: S?
		private var data: [Character]
		private var runningDemand: Subscribers.Demand = .max(0)
		private var isFinished = false
		private var isProcessingRequest = false	// make this Atomic to be threadsafe

		init(subscriber: S, data: [Character]) {
			self.subscriber = subscriber
			self.data = data
		}

		func request(_ demand: Subscribers.Demand) {
			guard !isFinished else { return }
			guard let subscriber = subscriber else { return }
			guard data.count > 0 else { return sendError(.inputStringWasEmpty) }

			runningDemand += demand
//Swift.print("DEMAND:", runningDemand.max ?? -1)
			if isProcessingRequest == true {
//Swift.print("ADDED:", demand.max ?? -1)
				return
			} else {
				isProcessingRequest = true
			}

			while runningDemand > 0 && !data.isEmpty {
				let count = computeSendCount()
				let tempData: [Character] = Array( data.prefix(upTo: count) )
				let stillDesired = subscriber.receive(tempData)

				// Only update counts and data AFTER sending receive
				data.removeSubrange(0..<count)
				runningDemand -= count
//Swift.print("RUNNING DEMAND:", runningDemand.max ?? -1, "EXPECTED:", stillDesired.max ?? -1, "COUNT:", count)
				if let runningDesired = runningDemand.max, let stillDesired = stillDesired.max {
					assert(runningDesired == stillDesired)
				}
			}

			if data.isEmpty {
				subscriber.receive(completion: .finished)
				isFinished = true
			}

			isProcessingRequest = false
		}

		private func sendError(_ error: SPErrors) {
			subscriber?.receive(completion: .failure(error))
		}

		private func computeSendCount() -> Int {
			let count: Int
			if let demand = runningDemand.max {
				//count = data.count < demand ? data.count : demand
				count = Swift.min(data.count, demand)
			} else {
				count = data.count
			}
			return count
		}

		func cancel() {
			isFinished = true
		}
	}

}

print("TEST 1")
do {
	var count = 0
	let _ = StringPublisher(string: "Hello World").sink(
		receiveCompletion: { completion in
			switch completion {
			case .failure(let err):
				print("ERROR: ", err)
			case .finished:
				print("FINISHED")
			}
		}) { (chars: [Character]) in
			chars.forEach({ print(count == 0 ? "Char:" : " ", $0, terminator: ""); count += 1 })
		}
}

final class StringSubscriber: Subscriber {
	typealias Input = [Character]
	typealias Failure = Error

	var subscription: Subscription?
	var count = 0

	func receive(subscription: Subscription) {
		self.subscription = subscription
		self.subscription?.request(.max(1))
	}

	func receive(_ input: Input) -> Subscribers.Demand {
		input.forEach({ print(count == 0 ? "Chars:" : " ", $0, terminator: ""); self.count += 1 })
		subscription?.request(.max(1))
		return .max(1)
	}

	func receive(completion: Subscribers.Completion<Failure>) {
		print("\nSubscriber completion: \(completion)")
		self.subscription = nil
	}
}

print("TEST 2")
do {
	let publisher = StringPublisher(string: "Hello World")
	let subcriber = StringSubscriber()
	publisher.subscribe(subcriber)
}

struct UpperCasePublisher: Publisher {
	typealias Output = [Character]
	typealias Failure = Error

	let upstreamPublisher: AnyPublisher<Output, Error>

	init(upstream: AnyPublisher<Output, Error>) {
		self.upstreamPublisher = upstream
	}

	func receive<S>(subscriber: S) where
		S: Subscriber,
		S.Failure == Self.Failure,
		S.Input == Self.Output
	{
		let subscription = UpperCaseSubscription(subscriber: subscriber, upstream: upstreamPublisher)
		upstreamPublisher.subscribe(subscription)
	}


	final class UpperCaseSubscription<S, P: Publisher>: Subscription, Subscriber where
		S: Subscriber,
		S.Input == Output,
		S.Failure == Error
	{
		typealias Input = P.Output 		// for Subscriber
		typealias Failure = P.Failure	// for Subscriber

		private var data: [Character] = []
		private var isProcessingRequest = false	// make this Atomic to be threadsafe
		//private var isOperational: Bool { !isUpstreamFinished && !isDownstreamCancelled }

		// Upstream Related
		private var upstreamSubscription: Subscription? // AnySubscriber<Output, Error>?
		private var isUpstreamFinished = false

		// Downstream Related
		private var downstreamSubscriber: S?
		private var isDownstreamCancelled = false
		private var runningDemand: Subscribers.Demand = .max(0)

		init(subscriber: S, upstream: P) {
			self.downstreamSubscriber = subscriber
		}

		// MARK: - Downstream Subscriber

		func request(_ demand: Subscribers.Demand) {
			guard !isDownstreamCancelled else { return }
			guard let downstreamSubscriber = downstreamSubscriber else { return }

			runningDemand += demand

			if isProcessingRequest == true {
				return
			} else {
				isProcessingRequest = true
			}

			while runningDemand > 0 && !data.isEmpty {
				let count = computeSendCount()
				let tempData: [Character] = Array( data.prefix(upTo: count) )
				let stillDesired = downstreamSubscriber.receive(tempData)

				// Only update counts and data AFTER sending receive
				data.removeSubrange(0..<count)
				runningDemand -= count
				if let runningDesired = runningDemand.max, let stillDesired = stillDesired.max {
					assert(runningDesired == stillDesired)
				}
			}

			if isUpstreamFinished && data.isEmpty {
				downstreamSubscriber.receive(completion: .finished)
			}

			isProcessingRequest = false
		}

		func cancel() {
			isDownstreamCancelled = true

			upstreamSubscription?.cancel()
			self.upstreamSubscription = nil
		}

		private func computeSendCount() -> Int {
			let count: Int
			if let demand = runningDemand.max {
				count = Swift.min(data.count, demand)
			} else {
				count = data.count
			}
			return count
		}

		// MARK: - Upstream Subscription

		func receive(subscription: Subscription) {
			downstreamSubscriber?.receive(subscription: self)

			upstreamSubscription = subscription
			upstreamSubscription?.request(.max(1))
		}

		func receive(_ input: Input) -> Subscribers.Demand {
			guard let input = input as? [Character] else { fatalError() }

			input.forEach({
				let s = $0.uppercased()
				s.forEach({ data.append($0) })
			})

			upstreamSubscription?.request(.max(1))
			return .max(1)
		}

		func receive(completion: Subscribers.Completion<P.Failure>) {
			isUpstreamFinished = true

			switch completion {
			case .finished:
				request(.max(0)) // Trigger the publisher side to finished sending then send .finished
			case .failure(let error):
				downstreamSubscriber?.receive(completion: .failure(error))
			}
		}

	}

}

print("TEST 3: TO UPPER")
do {
	let p1 = StringPublisher(string: "Hello World")
	let p2 = UpperCasePublisher(upstream: p1.eraseToAnyPublisher())

	let subscriber = StringSubscriber()
	p2.subscribe(subscriber)
}

print("TEST 4: ERROR")
do {
	let p1 = StringPublisher(string: "")
	let p2 = UpperCasePublisher(upstream: p1.eraseToAnyPublisher())

	let subscriber = StringSubscriber()
	p2.subscribe(subscriber)
}

extension Publisher where Output == [Character], Failure == Error {
	func toUpper() -> AnyPublisher<Output, Failure> {
		let p2 = UpperCasePublisher(upstream: self.eraseToAnyPublisher())
		return p2.eraseToAnyPublisher()
	}
}

print("TEST 5: Operator 1")
do {
	print("Operator 1")
	let p2 = StringPublisher(string: "Hello World").toUpper()
	let subscriber = StringSubscriber()
	p2.subscribe(subscriber)
}

print("TEST 6: Operator 2")
do {
	var count = 0
	let _ = StringPublisher(string: "Hello World")
	.toUpper()
	.sink(
	 receiveCompletion: { completion in
		switch completion {
		case .failure(let err):
			print("\nERROR 2: ", err)
		case .finished:
			print("\nFINISHED 2")
		}
	 })
	 { (chars: [Character]) in
		chars.forEach({ print(count == 0 ? "Char:" : " ", $0, terminator: ""); count += 1 })
	 }
 }
