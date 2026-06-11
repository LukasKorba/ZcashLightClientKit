//
//  SubmitPlanExecutor.swift
//  ZcashLightClientKit
//

import Foundation

/// Background-retry executor: tries the recorded plan endpoints sequentially
/// until one accepts. Background retry stays gentle — no fan-out.
final class SubmitPlanExecutor {
    private let endpointSubmitter: EndpointSubmitter
    private let logger: Logger

    init(endpointSubmitter: EndpointSubmitter, logger: Logger) {
        self.endpointSubmitter = endpointSubmitter
        self.logger = logger
    }

    func submit(transaction: CreatedTransaction, endpoints: [LightWalletEndpoint]) async throws {
        var lastError: Error?

        for endpoint in endpoints {
            do {
                try await endpointSubmitter.submit(transaction: transaction, to: endpoint)
                return
            } catch {
                logger.warn("Submit plan endpoint \(endpoint.host):\(endpoint.port) failed: \(error)")
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
    }
}
