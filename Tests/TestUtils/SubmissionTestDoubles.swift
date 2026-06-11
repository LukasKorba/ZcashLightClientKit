//
//  SubmissionTestDoubles.swift
//  TestUtils
//

import Foundation
import GRPC
import NIO
import NIOTransportServices
@testable import ZcashLightClientKit

final class RecordingCompactTxStreamerService: CompactTxStreamerProvider {
    var interceptors: CompactTxStreamerServerInterceptorFactoryProtocol? { nil }

    private(set) var endpoint: LightWalletEndpoint!

    private let sendResponse: SendResponse
    private let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .default)
    private let queue = DispatchQueue(label: "RecordingCompactTxStreamerService.queue")
    private var submittedTransactions: [Data] = []
    private var server: Server?

    init(sendResponse: SendResponse) throws {
        self.sendResponse = sendResponse
        self.endpoint = LightWalletEndpoint(address: "127.0.0.1", port: 0, secure: false)

        let server = try Server.insecure(group: eventLoopGroup)
            .withServiceProviders([self])
            .bind(host: "127.0.0.1", port: 0)
            .wait()

        self.server = server
        self.endpoint = LightWalletEndpoint(
            address: "127.0.0.1",
            port: server.channel.localAddress?.port ?? 0,
            secure: false,
            singleCallTimeoutInMillis: 5_000,
            streamingCallTimeoutInMillis: 5_000
        )
    }

    func stop() throws {
        try server?.close().wait()
        try eventLoopGroup.syncShutdownGracefully()
    }

    func recordedTransactions() -> [Data] {
        queue.sync { submittedTransactions }
    }

    func getLatestBlock(request: ChainSpec, context: StatusOnlyCallContext) -> EventLoopFuture<BlockID> {
        unimplementedUnary(on: context.eventLoop)
    }

    func getBlock(request: BlockID, context: StatusOnlyCallContext) -> EventLoopFuture<CompactBlock> {
        unimplementedUnary(on: context.eventLoop)
    }

    func getBlockNullifiers(request: BlockID, context: StatusOnlyCallContext) -> EventLoopFuture<CompactBlock> {
        unimplementedUnary(on: context.eventLoop)
    }

    func getBlockRange(request: BlockRange, context: StreamingResponseCallContext<CompactBlock>) -> EventLoopFuture<GRPCStatus> {
        unimplementedStreaming(on: context.eventLoop)
    }

    func getBlockRangeNullifiers(request: BlockRange, context: StreamingResponseCallContext<CompactBlock>) -> EventLoopFuture<GRPCStatus> {
        unimplementedStreaming(on: context.eventLoop)
    }

    func getTransaction(request: TxFilter, context: StatusOnlyCallContext) -> EventLoopFuture<RawTransaction> {
        unimplementedUnary(on: context.eventLoop)
    }

    func sendTransaction(request: RawTransaction, context: StatusOnlyCallContext) -> EventLoopFuture<SendResponse> {
        queue.sync {
            submittedTransactions.append(request.data)
        }
        return context.eventLoop.makeSucceededFuture(sendResponse)
    }

    func getTaddressTxids(request: TransparentAddressBlockFilter, context: StreamingResponseCallContext<RawTransaction>) -> EventLoopFuture<GRPCStatus> {
        unimplementedStreaming(on: context.eventLoop)
    }

    func getTaddressBalance(request: AddressList, context: StatusOnlyCallContext) -> EventLoopFuture<Balance> {
        unimplementedUnary(on: context.eventLoop)
    }

    func getTaddressBalanceStream(context: UnaryResponseCallContext<Balance>) -> EventLoopFuture<(StreamEvent<Address>) -> Void> {
        unimplementedUnary(on: context.eventLoop)
    }

    func getMempoolTx(request: Exclude, context: StreamingResponseCallContext<CompactTx>) -> EventLoopFuture<GRPCStatus> {
        unimplementedStreaming(on: context.eventLoop)
    }

    func getMempoolStream(request: ZcashLightClientKit.Empty, context: StreamingResponseCallContext<RawTransaction>) -> EventLoopFuture<GRPCStatus> {
        unimplementedStreaming(on: context.eventLoop)
    }

    func getTreeState(request: BlockID, context: StatusOnlyCallContext) -> EventLoopFuture<TreeState> {
        unimplementedUnary(on: context.eventLoop)
    }

    func getLatestTreeState(request: ZcashLightClientKit.Empty, context: StatusOnlyCallContext) -> EventLoopFuture<TreeState> {
        unimplementedUnary(on: context.eventLoop)
    }

    func getSubtreeRoots(request: GetSubtreeRootsArg, context: StreamingResponseCallContext<SubtreeRoot>) -> EventLoopFuture<GRPCStatus> {
        unimplementedStreaming(on: context.eventLoop)
    }

    func getAddressUtxos(request: GetAddressUtxosArg, context: StatusOnlyCallContext) -> EventLoopFuture<GetAddressUtxosReplyList> {
        unimplementedUnary(on: context.eventLoop)
    }

    func getAddressUtxosStream(request: GetAddressUtxosArg, context: StreamingResponseCallContext<GetAddressUtxosReply>) -> EventLoopFuture<GRPCStatus> {
        unimplementedStreaming(on: context.eventLoop)
    }

    func getLightdInfo(request: ZcashLightClientKit.Empty, context: StatusOnlyCallContext) -> EventLoopFuture<LightdInfo> {
        unimplementedUnary(on: context.eventLoop)
    }

    func ping(request: ZcashLightClientKit.Duration, context: StatusOnlyCallContext) -> EventLoopFuture<PingResponse> {
        unimplementedUnary(on: context.eventLoop)
    }

    private func unimplementedUnary<T>(on eventLoop: EventLoop) -> EventLoopFuture<T> {
        eventLoop.makeFailedFuture(GRPCStatus(code: .unimplemented, message: "Unused in test"))
    }

    private func unimplementedStreaming(on eventLoop: EventLoop) -> EventLoopFuture<GRPCStatus> {
        eventLoop.makeSucceededFuture(GRPCStatus(code: .unimplemented, message: "Unused in test"))
    }
}

final class EndpointSubmitterMock: EndpointSubmitter {
    enum Behavior {
        case succeed
        case succeedAfter(TimeInterval)
        case reject(code: Int, message: String)
        case failTransport
        /// Sleeps ~10s; only ends via cancellation. Records the cancellation.
        case hang
    }

    struct MockTransportError: Error {}

    private let queue = DispatchQueue(label: "EndpointSubmitterMock")
    private var behaviors: [String: Behavior] = [:]
    private var submitted: [LightWalletEndpoint] = []
    private var cancelled: [LightWalletEndpoint] = []

    func set(behavior: Behavior, for endpoint: LightWalletEndpoint) {
        queue.sync { behaviors[Self.key(endpoint)] = behavior }
    }

    func recordedSubmissions() -> [LightWalletEndpoint] {
        queue.sync { submitted }
    }

    func recordedCancellations() -> [LightWalletEndpoint] {
        queue.sync { cancelled }
    }

    func submit(transaction: CreatedTransaction, to endpoint: LightWalletEndpoint) async throws {
        queue.sync { submitted.append(endpoint) }
        let behavior = queue.sync { behaviors[Self.key(endpoint)] } ?? Behavior.succeed

        switch behavior {
        case .succeed:
            return

        case .succeedAfter(let delay):
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        case let .reject(code, message):
            throw TransactionEncoderError.submitError(code: code, message: message)

        case .failTransport:
            throw MockTransportError()

        case .hang:
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw MockTransportError()
            } catch is CancellationError {
                queue.sync { cancelled.append(endpoint) }
                throw CancellationError()
            }
        }
    }

    private static func key(_ endpoint: LightWalletEndpoint) -> String {
        "\(endpoint.host):\(endpoint.port)"
    }
}
