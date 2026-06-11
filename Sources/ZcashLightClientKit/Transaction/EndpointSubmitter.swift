//
//  EndpointSubmitter.swift
//  ZcashLightClientKit
//

import Foundation

/// Submits one transaction to one endpoint. The mock seam for offline tests.
protocol EndpointSubmitter {
    /// - Throws: `TransactionEncoderError.submitError` when the server rejects
    ///   the transaction; any other error indicates a transport-level failure.
    func submit(transaction: CreatedTransaction, to endpoint: LightWalletEndpoint) async throws
}

/// Submits over an ephemeral gRPC connection, respecting the Tor configuration.
final class GRPCEndpointSubmitter: EndpointSubmitter {
    private let torClient: TorClient
    private let sdkFlags: SDKFlags

    init(torClient: TorClient, sdkFlags: SDKFlags) {
        self.torClient = torClient
        self.sdkFlags = sdkFlags
    }

    func submit(transaction: CreatedTransaction, to endpoint: LightWalletEndpoint) async throws {
        let service = LightWalletGRPCServiceOverTor(endpoint: endpoint, tor: torClient)

        let mode: ServiceMode
        if await sdkFlags.torEnabled {
            mode = ServiceMode.txIdGroup(prefix: "submit", txId: transaction.txId)
        } else {
            mode = ServiceMode.direct
        }

        let response: LightWalletServiceResponse
        do {
            response = try await service.submit(spendTransaction: transaction.raw, mode: mode)
        } catch {
            await service.closeConnections()
            throw error
        }

        await service.closeConnections()

        guard response.errorCode >= 0 else {
            throw TransactionEncoderError.submitError(
                code: Int(response.errorCode),
                message: response.errorMessage
            )
        }
    }
}
