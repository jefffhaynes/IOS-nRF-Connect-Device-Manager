/*
 * Copyright (c) 2017-2018 Runtime Inc.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import CoreBluetooth

// MARK: - FirmwareUpgradeManager

public class FirmwareUpgradeManager : FirmwareUpgradeController, ConnectionObserver {
    
    private let imageManager: ImageManager
    private let defaultManager: DefaultManager
    private let basicManager: BasicManager
    private weak var delegate: FirmwareUpgradeDelegate?
    
    /// Cyclic reference is used to prevent from releasing the manager
    /// in the middle of an update. The reference cycle will be set
    /// when upgrade was started and released on success, error or cancel.
    private var cyclicReferenceHolder: (() -> FirmwareUpgradeManager)?
    
    private var images: [FirmwareUpgradeImage]!
    private var configuration: FirmwareUpgradeConfiguration!
    
    private var state: FirmwareUpgradeState
    private var paused: Bool
    
    /// Logger delegate may be used to obtain logs.
    public weak var logDelegate: McuMgrLogDelegate? {
        didSet {
            imageManager.logDelegate = logDelegate
            defaultManager.logDelegate = logDelegate
        }
    }
    
    /// Upgrade mode. The default mode is .confirmOnly.
    public var mode: FirmwareUpgradeMode = .confirmOnly
    
    /// Estimated time required for swapping images, in seconds.
    /// If the mode is set to `.testAndConfirm`, the manager will try to
    /// reconnect after this time. 0 by default.
    public var estimatedSwapTime: TimeInterval = 0.0
    private var resetResponseTime: Date?
    
    //**************************************************************************
    // MARK: Initializer
    //**************************************************************************
    
    public init(transporter: McuMgrTransport, delegate: FirmwareUpgradeDelegate?) {
        self.imageManager = ImageManager(transporter: transporter)
        self.defaultManager = DefaultManager(transporter: transporter)
        self.basicManager = BasicManager(transporter: transporter)
        self.delegate = delegate
        self.state = .none
        self.paused = false
    }
    
    //**************************************************************************
    // MARK: Control Functions
    //**************************************************************************
    
    /// Start the firmware upgrade.
    ///
    /// Use this convenience call of ``start(images:using:)`` if you're only
    /// updating the App Core (i.e. no Multi-Image).
    /// - parameter data: `Data` to upload to App Core (Image 0).
    /// - parameter configuration: Fine-tuning of details regarding the upgrade process.
    public func start(data: Data, using configuration: FirmwareUpgradeConfiguration = FirmwareUpgradeConfiguration()) throws {
        try start(images: [(0, data)], using: configuration)
    }
    
    /// Start the firmware upgrade.
    ///
    /// This is the full-featured API to start DFU update, including support for Multi-Image uploads.
    /// - parameter images: An Array of (Image, `Data`) pairs with the Image Core/Index and its corresponding `Data` to upload.
    /// - parameter configuration: Fine-tuning of details regarding the upgrade process.
    public func start(images: [(Int, Data)], using configuration: FirmwareUpgradeConfiguration = FirmwareUpgradeConfiguration()) throws {
        objc_sync_enter(self)
        defer {
            objc_sync_exit(self)
        }
        
        guard state == .none else {
            log(msg: "Firmware upgrade is already in progress", atLevel: .warning)
            return
        }
        
        self.images = try images.map { try FirmwareUpgradeImage($0) }
        self.configuration = configuration
        
        // Grab a strong reference to something holding a strong reference to self.
        cyclicReferenceHolder = { return self }
        
        let numberOfBytes = images.reduce(0, { $0 + $1.1.count })
        log(msg: "Upgrading with \(images.count) images in mode '\(mode)' (\(numberOfBytes) bytes)...",
            atLevel: .application)
        if #available(iOS 10.0, *) {
            dispatchPrecondition(condition: .onQueue(.main))
        } else {
            assert(Thread.isMainThread)
        }
        delegate?.upgradeDidStart(controller: self)
        
        requestMcuMgrParameters()
    }
    
    public func cancel() {
        objc_sync_enter(self)
        if state == .upload {
            imageManager.cancelUpload()
            paused = false
            log(msg: "Upgrade cancelled", atLevel: .application)
        }
        objc_sync_exit(self)
    }
    
    public func pause() {
        objc_sync_enter(self)
        if state.isInProgress() && !paused {
            paused = true
            if state == .upload {
                imageManager.pauseUpload()
            }
            log(msg: "Upgrade paused", atLevel: .application)
        }
        objc_sync_exit(self)
    }
    
    public func resume() {
        objc_sync_enter(self)
        if paused {
            paused = false
            log(msg: "Upgrade resumed", atLevel: .application)
            currentState()
        }
        objc_sync_exit(self)
    }
    
    public func isPaused() -> Bool {
        return paused
    }
    
    public func isInProgress() -> Bool {
        return state.isInProgress() && !paused
    }
    
    /// Sets the MTU of the image upload. The MTU must be between 23 and 1024
    /// (inclusive). The upload MTU determines the number of bytes sent in each
    /// upload request. The MTU will default the the maximum available to the
    /// phone and may change automatically if the end device's MTU is lower.
    ///
    /// - parameter mtu: The mtu to use in image upload.
    ///
    /// - returns: true if the mtu was within range, false otherwise
    public func setUploadMtu(mtu: Int) -> Bool {
        return imageManager.setMtu(mtu)
    }
    
    //**************************************************************************
    // MARK: Firmware Upgrade State Machine
    //**************************************************************************
    
    private func setState(_ state: FirmwareUpgradeState) {
        objc_sync_enter(self)
        let previousState = self.state
        self.state = state
        if state != previousState {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.upgradeStateDidChange(from: previousState, to: state)
            }
        }
        objc_sync_exit(self)
    }
    
    private func requestMcuMgrParameters() {
        setState(.requestMcuMgrParameters)
        if !paused {
            log(msg: "Requesting McuMgr parameters...", atLevel: .debug)
            defaultManager.params(callback: self.mcuManagerParametersCallback)
        }
    }
    
    private func validate() {
        setState(.validate)
        if !paused {
            log(msg: "Sending Image List command...", atLevel: .application)
            imageManager.list(callback: validateCallback)
        }
    }
    
    private func upload() {
        setState(.upload)
        if !paused {
            log(msg: "Uploading images...", atLevel: .application)
            let imagesToUpload = images
                .filter { !$0.uploaded }
                .sorted(by: <)
                .map { ImageManager.Image($0.image, $0.data) }
            _ = imageManager.upload(images: imagesToUpload, using: configuration, delegate: self)
        }
    }
    
    private func test(_ image: FirmwareUpgradeImage) {
        setState(.test)
        if !paused {
            log(msg: "Sending Test command for image \(image.image)...", atLevel: .application)
            imageManager.test(hash: [UInt8](image.hash), callback: testCallback)
        }
    }
    
    private func confirm(_ image: FirmwareUpgradeImage) {
        setState(.confirm)
        if !paused {
            log(msg: "Sending Confirm command for image \(image.image)...", atLevel: .application)
            imageManager.confirm(hash: [UInt8](image.hash), callback: confirmCallback)
        }
    }
    
    private func verify() {
        setState(.confirm)
        if !paused {
            // This will confirm the image on slot 0
            log(msg: "Sending Config command...", atLevel: .application)
            imageManager.confirm(callback: confirmCallback)
        }
    }
    
    private func reset() {
        setState(.reset)
        if !paused {
            log(msg: "Sending Reset command...", atLevel: .application)
            defaultManager.transporter.addObserver(self)
            defaultManager.reset(callback: resetCallback)
        }
    }
    
    private func success() {
        setState(.success)
        objc_sync_enter(self)
        state = .none
        paused = false
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.upgradeDidComplete()
        }
        // Release cyclic reference.
        cyclicReferenceHolder = nil
        objc_sync_exit(self)
    }
    
    private func fail(error: Error) {
        objc_sync_enter(self)
        log(msg: error.localizedDescription, atLevel: .error)
        let tmp = state
        state = .none
        paused = false
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.upgradeDidFail(inState: tmp, with: error)
        }
        // Release cyclic reference.
        cyclicReferenceHolder = nil
        objc_sync_exit(self)
    }
    
    private func currentState() {
        objc_sync_enter(self)
        defer {
            objc_sync_exit(self)
        }
        if !paused {
            switch state {
            case .requestMcuMgrParameters:
                requestMcuMgrParameters()
            case .validate:
                validate()
            case .upload:
                imageManager.continueUpload()
            case .test:
                guard let nextImageToTest = self.images.first(where: { !$0.tested }) else { return }
                test(nextImageToTest)
            case .reset:
                reset()
            case .confirm:
                guard let nextImageToConfirm = self.images.first(where: { !$0.confirmed }) else { return }
                confirm(nextImageToConfirm)
            default:
                break
            }
        }
    }
    
    //**************************************************************************
    // MARK: - McuMgrCallbacks
    //**************************************************************************
    
    /// Callback for the VALIDATE state.
    ///
    /// This callback will fail the upgrade on error and continue to the next
    /// state on success.
    private lazy var validateCallback: McuMgrCallback<McuMgrImageStateResponse> =
    { [weak self] (response: McuMgrImageStateResponse?, error: Error?) in
        // Ensure the manager is not released.
        guard let self = self else { return }
        
        // Check for an error.
        if let error = error {
            self.fail(error: error)
            return
        }
        guard let response = response else {
            self.fail(error: FirmwareUpgradeError.unknown("Validation response is nil!"))
            return
        }
        self.log(msg: "Validation response: \(response)", atLevel: .application)
        // Check for McuMgrReturnCode error.
        if !response.isSuccess() {
            self.fail(error: FirmwareUpgradeError.mcuMgrReturnCodeError(response.returnCode))
            return
        }
        // Check that the image array exists.
        guard let responseImages = response.images, responseImages.count > 0 else {
            self.fail(error: FirmwareUpgradeError.invalidResponse(response))
            return
        }
        
        for j in 0..<self.images.count {
            let primary: McuMgrImageStateResponse.ImageSlot! = responseImages.first(where: { $0.image == j && $0.slot == 0 })
            if primary != nil {
                if Data(primary.hash) == self.images[j].hash {
                    self.images[j].uploaded = true
                    
                    if primary.confirmed || primary.permanent {
                        // The new firmware is already active and confirmed.
                        self.images[j].confirmed = true
                        continue
                    } else {
                        // The new firmware is in test mode.
                        switch self.mode {
                        case .confirmOnly, .testAndConfirm:
                            self.confirm(self.images[j])
                            return
                        case .testOnly:
                            continue
                        }
                    }
                }
            }
            
            guard let secondary = responseImages.first(where: { $0.image == j && $0.slot == 1 }) else {
                continue
            }

            // Check if the firmware has already been uploaded.
            if Data(secondary.hash) == self.images[j].hash {
                // Firmware is identical to the one in slot 1. No need to send
                // anything.

                // If the test and confirm commands were not sent, proceed
                // with next state.
                if !secondary.pending {
                    switch self.mode {
                    case .testOnly, .testAndConfirm:
                        self.test(self.images[j])
                    case .confirmOnly:
                        self.confirm(self.images[j])
                    }
                    return
                }

                // If the image was already confirmed, reset (if confirm was
                // intended), or fail.
                if secondary.permanent {
                    switch self.mode {
                    case .confirmOnly, .testAndConfirm:
                        self.reset()
                    case .testOnly:
                        self.fail(error: FirmwareUpgradeError.unknown("Image \(j) already confirmed. Can't be tested!"))
                    }
                    return
                }

                // If image was not confirmed, but test command was sent,
                // confirm or reset.
                switch self.mode {
                case .confirmOnly:
                    self.confirm(self.images[j])
                    return
                case .testOnly, .testAndConfirm:
                    self.reset()
                    return
                }
            } else {
                // If the image in secondary slot is confirmed, we won't be able to erase or
                // test the slot. Therefore, we confirm the image in the core's primary slot
                // to allow us to modify the image in the secondary slot.
                if secondary.confirmed {
                    guard primary != nil else { continue }
                    self.validationConfirm(hash: primary.hash)
                    return
                }

                // If the image in secondary slot is pending, we won't be able to
                // erase or test the slot. Therefore, We must reset the device and
                // revalidate the new image state.
                if secondary.pending {
                    self.defaultManager.transporter.addObserver(self)
                    self.defaultManager.reset(callback: self.resetCallback)
                    return
                }
            }
        }
        
        guard !self.images.filter({ !$0.uploaded }).isEmpty else {
            // The new firmware is already active and confirmed.
            // No need to do anything.
            self.success()
            return
        }
        
        // Validation successful, begin with image upload.
        self.upload()
    }
    
    func validationConfirm(hash: [UInt8]?) {
        self.imageManager.confirm(hash: hash) { [weak self] (response, error) in
            guard let self = self else {
                return
            }
            if let error = error {
                self.fail(error: error)
                return
            }
            guard let response = response else {
                self.fail(error: FirmwareUpgradeError.unknown("Test response is nil!"))
                return
            }
            if !response.isSuccess() {
                self.fail(error: FirmwareUpgradeError.mcuMgrReturnCodeError(response.returnCode))
                return
            }
            self.validate()
        }
    }
    
    /// Callback for the TEST state.
    ///
    /// This callback will fail the upgrade on error and continue to the next
    /// state on success.
    private lazy var testCallback: McuMgrCallback<McuMgrImageStateResponse> =
    { [weak self] (response: McuMgrImageStateResponse?, error: Error?) in
        // Ensure the manager is not released.
        guard let self = self else {
            return
        }
        // Check for an error.
        if let error = error {
            self.fail(error: error)
            return
        }
        guard let response = response else {
            self.fail(error: FirmwareUpgradeError.unknown("Test response is nil!"))
            return
        }
        self.log(msg: "Test response: \(response)", atLevel: .application)
        // Check for McuMgrReturnCode error.
        if !response.isSuccess() {
            self.fail(error: FirmwareUpgradeError.mcuMgrReturnCodeError(response.returnCode))
            return
        }
        // Check that the image array exists.
        guard let responseImages = response.images else {
            self.fail(error: FirmwareUpgradeError.invalidResponse(response))
            return
        }

        // Check that we have the correct number of images in the responseImages array.
        guard responseImages.count >= self.images.count else {
            self.fail(error: FirmwareUpgradeError.unknown("Test response expected \(self.images.count) or more, but received \(responseImages.count) instead."))
            return
        }
        
        for j in 0..<self.images.count {
            // Check that the image in secondary slot is pending (i.e. test succeeded).
            guard let secondary = responseImages.first(where: { $0.image == j && $0.slot == 1 }) else {
                self.fail(error: FirmwareUpgradeError.unknown("Unable to find secondary slot for Image \(j) in Test Response."))
                return
            }
            
            guard secondary.pending else {
                // For every image we upload, we need to send it the TEST Command.
                guard self.images[j].tested else {
                    self.test(self.images[j])
                    return
                }
                
                // If we've sent it the TEST Command, the secondary slot must be in pending state to pass test.
                self.fail(error: FirmwareUpgradeError.unknown("Image \(j) is not in a pending state."))
                return
            }
            self.images[j].tested = true
        }
        
        // Test image succeeded. Begin device reset.
        self.log(msg: "Test Succeeded. Proceeding with device reset.", atLevel: .application)
        self.reset()
    }
    
    /// Callback for Erase App Settings Command.
    private lazy var eraseAppSettingsCallback: McuMgrCallback<McuMgrResponse> = { [weak self] (response: McuMgrResponse?, error: Error?) in
        guard let self = self else { return }
        
        if let error = error {
            self.fail(error: error)
            return
        }
        
        guard let response = response else {
            self.fail(error: FirmwareUpgradeError.unknown("Erase App Settings Response was nil!"))
            return
        }
        
        // rc != 0 is expected, DFU should continue.
        guard response.isSuccess() || response.rc != 0 else {
            self.fail(error: FirmwareUpgradeError.mcuMgrReturnCodeError(response.returnCode))
            return
        }
        self.log(msg: "Erasing app settings completed", atLevel: .application)
        
        // Set to false so uploadDidFinish() doesn't loop forever.
        self.configuration.eraseAppSettings = false
        self.uploadDidFinish()
    }
    
    /// Callback for devices running NCS firmware version 2.0 or later, which support McuMgrParameters call.
    ///
    /// Error handling here is not considered important because we don't expect many devices to support this.
    private lazy var mcuManagerParametersCallback: McuMgrCallback<McuMgrParametersResponse> = { [weak self] (response: McuMgrParametersResponse?, error: Error?) in
        
        guard let self = self else { return }
        
        guard error == nil, let response = response, response.rc != 8 else {
            self.configuration.reassemblyBufferSize = 0
            self.validate() // Continue Upload
            return
        }
        
        self.log(msg: "Setting SAR buffer size to \(response.bufferSize) bytes", atLevel: .debug)
        self.configuration.reassemblyBufferSize = response.bufferSize
        self.validate() // Continue Upload
    }
    
    /// Callback for the RESET state.
    ///
    /// This callback will fail the upgrade on error. On success, the reset
    /// poller will be started after a 3 second delay.
    private lazy var resetCallback: McuMgrCallback<McuMgrResponse> =
    { [weak self] (response: McuMgrResponse?, error: Error?) in
        // Ensure the manager is not released.
        guard let self = self else {
            return
        }
        // Check for an error.
        if let error = error {
            self.fail(error: error)
            return
        }
        guard let response = response else {
            self.fail(error: FirmwareUpgradeError.unknown("Reset response is nil!"))
            return
        }
        // Check for McuMgrReturnCode error.
        if !response.isSuccess() {
            self.fail(error: FirmwareUpgradeError.mcuMgrReturnCodeError(response.returnCode))
            return
        }
        self.resetResponseTime = Date()
        self.log(msg: "Reset request sent. Waiting for reset...", atLevel: .application)
    }
    
    public func transport(_ transport: McuMgrTransport, didChangeStateTo state: McuMgrTransportState) {
        transport.removeObserver(self)
        // Disregard connected state.
        guard state == .disconnected else {
            return
        }
        self.log(msg: "Device has disconnected (reset). Reconnecting...", atLevel: .info)
        let timeSinceReset: TimeInterval
        if let resetResponseTime = resetResponseTime {
            let now = Date()
            timeSinceReset = now.timeIntervalSince(resetResponseTime)
        } else {
            // Fallback if state changed prior to `resetResponseTime` is set.
            timeSinceReset = 0
        }
        let remainingTime = estimatedSwapTime - timeSinceReset
        if remainingTime > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) { [weak self] in
                self?.reconnect()
            }
        } else {
            reconnect()
        }
    }
    
    /// Reconnect to the device and continue the
    private func reconnect() {
        imageManager.transporter.connect { [weak self] result in
            guard let self = self else {
                return
            }
            switch result {
            case .connected:
                self.log(msg: "Reconnect successful.", atLevel: .info)
            case .deferred:
                self.log(msg: "Reconnect deferred.", atLevel: .info)
            case .failed(let error):
                self.log(msg: "Reconnect failed. \(error)", atLevel: .error)
                self.fail(error: error)
                return
            }
            
            // Continue the upgrade after reconnect.
            switch self.state {
            case .requestMcuMgrParameters:
                self.requestMcuMgrParameters()
            case .validate:
                self.validate()
            case .reset:
                switch self.mode {
                case .testAndConfirm:
                    self.verify()
                default:
                    self.log(msg: "Upgrade complete", atLevel: .application)
                    self.success()
                }
            default:
                break
            }
        }
    }
    
    /// Callback for the CONFIRM state.
    ///
    /// This callback will fail the upload on error or move to the next state on
    /// success.
    private lazy var confirmCallback: McuMgrCallback<McuMgrImageStateResponse> =
    { [weak self] (response: McuMgrImageStateResponse?, error: Error?) in
        // Ensure the manager is not released.
        guard let self = self else {
            return
        }
        // Check for an error.
        if let error = error {
            self.fail(error: error)
            return
        }
        guard let response = response else {
            self.fail(error: FirmwareUpgradeError.unknown("Confirmation response is nil!"))
            return
        }
        self.log(msg: "Confirmation response: \(response)", atLevel: .application)
        // Check for McuMgrReturnCode error.
        if !response.isSuccess() {
            self.fail(error: FirmwareUpgradeError.mcuMgrReturnCodeError(response.returnCode))
            return
        }
        // Check that the image array exists.
        guard let responseImages = response.images, responseImages.count > 0 else {
            self.fail(error: FirmwareUpgradeError.invalidResponse(response))
            return
        }
        
        for j in 0..<self.images.count {
            switch self.mode {
            case .confirmOnly:
                guard !self.images[j].confirmed else {
                    continue
                }
                
                // If not already confirmed/uploaded, the new image should be in slot 1.
                guard let secondary = responseImages.first(where: { $0.image == j && $0.slot == 1 }) else {
                    // Unable to find Image j in secondary slot
                    
                    guard let primary = responseImages.first(where: { $0.image == j && $0.slot == 0 }) else {
                        self.fail(error: FirmwareUpgradeError.invalidResponse(response))
                        return
                    }
                    
                    self.images[j].confirmed = true
                    continue
                }
                
                // Check that the new image is in permanent state.
                guard secondary.permanent else {
                    // If a TEST command was sent before for the image that is to be confirmed we have to reset.
                    // It is not possible to confirm such image until the device is reset.
                    // A new DFU operation has to be performed to confirm the image.
                    guard !secondary.pending else {
                        self.reset()
                        return
                    }
                    guard self.images[j].confirmed else {
                        self.confirm(self.images[j])
                        return
                    }
                    
                    // If we've sent it the CONFIRM Command, the secondary slot must be in PERMANENT state.
                    self.fail(error: FirmwareUpgradeError.unknown("Image \(secondary.image) in slot \(secondary.slot) is not in a permanent state."))
                    return
                }
                
                self.images[j].confirmed = true
            case .testAndConfirm:
                if let primary = responseImages.first(where: { $0.image == j && $0.slot == 0 }) {
                    // If Primary is available, check that the upgrade image has successfully booted.
                    if Data(primary.hash) != self.images[j].hash {
                        self.fail(error: FirmwareUpgradeError.unknown("Device failed to boot into Image \(primary.image)."))
                        return
                    }
                    // Check that the new image is in confirmed state.
                    if !primary.confirmed {
                        self.fail(error: FirmwareUpgradeError.unknown("Image \(primary.image) is not in a confirmed state."))
                        return
                    }
                    self.images[j].confirmed = true
                }
            case .testOnly:
                // Impossible state. Ignore.
                return
            }
        }
        
        self.log(msg: "Upgrade complete.", atLevel: .application)
        switch self.mode {
        case .confirmOnly:
            self.reset()
        case .testAndConfirm:
            self.success()
        case .testOnly:
            // Impossible!
            return
        }
    }
}

private extension FirmwareUpgradeManager {
    
    func log(msg: @autoclosure () -> String, atLevel level: McuMgrLogLevel) {
        logDelegate?.log(msg(), ofCategory: .dfu, atLevel: level)
    }
}

// MARK: - FirmwareUpgradeConfiguration

public struct FirmwareUpgradeConfiguration {
    
    /// If enabled, after succesful upload but before test/confirm/reset phase, an Erase App Settings Command will be sent and awaited before proceeding.
    public var eraseAppSettings: Bool
    /// If set to a value larger than 1, this enables SMP Pipelining, wherein multiple packets of data ('chunks') are sent at once before awaiting a response, which can lead to a big increase in transfer speed if the receiving hardware supports this feature.
    public var pipelineDepth: Int
    /// Necessary to set when Pipeline Length is larger than 1 (SMP Pipelining Enabled) to predict offset jumps as multiple
    /// packets are sent.
    public var byteAlignment: ImageUploadAlignment
    /// If set, it is used instead of the MTU Size as the maximum size of the packet. It is designed to be used with a size
    /// larger than the MTU, meaning larger Data chunks per Sequence Number, trusting the reassembly Buffer on the receiving
    /// side to merge it all back. Thus, increasing transfer speeds.
    ///
    /// Can be used in conjunction with SMP Pipelining.
    public var reassemblyBufferSize: UInt64
    
    public init(eraseAppSettings: Bool = true, pipelineDepth: Int = 1, byteAlignment: ImageUploadAlignment = .disabled,
                reassemblyBufferSize: UInt64 = 0) {
        self.eraseAppSettings = eraseAppSettings
        self.pipelineDepth = pipelineDepth
        self.byteAlignment = byteAlignment
        self.reassemblyBufferSize = reassemblyBufferSize
    }
}

//******************************************************************************
// MARK: - ImageUploadDelegate
//******************************************************************************

extension FirmwareUpgradeManager: ImageUploadDelegate {
    
    public func uploadProgressDidChange(bytesSent: Int, imageSize: Int, timestamp: Date) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.uploadProgressDidChange(bytesSent: bytesSent, imageSize: imageSize, timestamp: timestamp)
        }
    }
    
    public func uploadDidFail(with error: Error) {
        // If the upload fails, fail the upgrade.
        fail(error: error)
    }
    
    public func uploadDidCancel() {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.upgradeDidCancel(state: .none)
        }
        state = .none
        // Release cyclic reference.
        cyclicReferenceHolder = nil
    }
    
    public func uploadDidFinish() {
        // Before we can move on, we must check whether the user requested for App Core Settings
        // to be erased.
        if configuration.eraseAppSettings {
            log(msg: "Sending Erase App Storage command...", atLevel: .application)
            basicManager.eraseAppSettings(callback: eraseAppSettingsCallback)
            return
        }
        
        // If eraseAppSettings command was sent or was not requested, we can continue.
        switch mode {
        case .confirmOnly:
            guard let firstUnconfirmedImage = self.images.first(where: { !$0.confirmed }) else {
                log(msg: "No images to confirm in \(#function).", atLevel: .warning)
                return
            }
            confirm(firstUnconfirmedImage)
        case .testOnly, .testAndConfirm:
            guard let firstUntestedImage = self.images.first(where: { !$0.tested }) else {
                log(msg: "No images to test in \(#function).", atLevel: .warning)
                return
            }
            test(firstUntestedImage)
        }
    }
}

//******************************************************************************
// MARK: - FirmwareUpgradeError
//******************************************************************************

public enum FirmwareUpgradeError: Error {
    case unknown(String)
    case invalidResponse(McuMgrResponse)
    case mcuMgrReturnCodeError(McuMgrReturnCode)
    case connectionFailedAfterReset
}

extension FirmwareUpgradeError: LocalizedError {
    
    public var errorDescription: String? {
        switch self {
        case .unknown(let message):
            return message
        case .invalidResponse(let response):
            return "Invalid response: \(response)."
        case .mcuMgrReturnCodeError(let code):
            return "Remote error: \(code)."
        case .connectionFailedAfterReset:
            return "Connection failed after reset."
        }
    }
    
}

//******************************************************************************
// MARK: - FirmwareUpgradeState
//******************************************************************************

public enum FirmwareUpgradeState {
    case none, requestMcuMgrParameters, validate, upload, test, reset, confirm, success
    
    func isInProgress() -> Bool {
        return self != .none
    }
}

//******************************************************************************
// MARK: - FirmwareUpgradeMode
//******************************************************************************

public enum FirmwareUpgradeMode: CustomStringConvertible, CaseIterable {
    /// When this mode is set, the manager will send the test and reset commands
    /// to the device after the upload is complete. The device will reboot and
    /// will run the new image on its next boot. If the new image supports
    /// auto-confirm feature, it will try to confirm itself and change state to
    /// permanent. If not, test image will run just once and will be swapped
    /// again with the original image on the next boot.
    ///
    /// Use this mode if you just want to test the image, when it can confirm
    /// itself.
    case testOnly
    
    /// When this flag is set, the manager will send confirm and reset commands
    /// immediately after upload.
    ///
    /// Use this mode if when the new image does not support both auto-confirm
    /// feature and SMP service and could not be confirmed otherwise.
    case confirmOnly
    
    /// When this flag is set, the manager will first send test followed by
    /// reset commands, then it will reconnect to the new application and will
    /// send confirm command.
    ///
    /// Use this mode when the new image supports SMP service and you want to
    /// test it before confirming.
    case testAndConfirm
    
    public var description: String {
        switch self {
        case .testOnly:
            return "Test Only"
        case .confirmOnly:
            return "Confirm Only"
        case .testAndConfirm:
            return "Test And Confirm"
        }
    }
}

//******************************************************************************
// MARK: - FirmwareUpgradeDelegate
//******************************************************************************

/// Callbacks for firmware upgrades started using FirmwareUpgradeManager.
public protocol FirmwareUpgradeDelegate: AnyObject {
    
    /// Called when the upgrade has started.
    ///
    /// - parameter controller: The controller that may be used to pause,
    ///   resume or cancel the upgrade.
    func upgradeDidStart(controller: FirmwareUpgradeController)
    
    /// Called when the firmware upgrade state has changed.
    ///
    /// - parameter previousState: The state before the change.
    /// - parameter newState: The new state.
    func upgradeStateDidChange(from previousState: FirmwareUpgradeState, to newState: FirmwareUpgradeState)
    
    /// Called when the firmware upgrade has succeeded.
    func upgradeDidComplete()
    
    /// Called when the firmware upgrade has failed.
    ///
    /// - parameter state: The state in which the upgrade has failed.
    /// - parameter error: The error.
    func upgradeDidFail(inState state: FirmwareUpgradeState, with error: Error)
    
    /// Called when the firmware upgrade has been cancelled using cancel()
    /// method. The upgrade may be cancelled only during uploading the image.
    /// When the image is uploaded, the test and/or confirm commands will be
    /// sent depending on the mode.
    func upgradeDidCancel(state: FirmwareUpgradeState)
    
    /// Called whnen the upload progress has changed.
    ///
    /// - parameter bytesSent: Number of bytes sent so far.
    /// - parameter imageSize: Total number of bytes to be sent.
    /// - parameter timestamp: The time that the successful response packet for
    ///   the progress was received.
    func uploadProgressDidChange(bytesSent: Int, imageSize: Int, timestamp: Date)
}

// MARK: - FirmwareUpgradeImage

fileprivate struct FirmwareUpgradeImage {
    
    // MARK: Properties
    
    let image: Int
    let data: Data
    let hash: Data
    var uploaded: Bool
    var tested: Bool
    var confirmed: Bool
    
    // MARK: Init
    
    init(_ image: (index: Int, data: Data)) throws {
        self.image = image.index
        self.data = image.data
        self.hash = try McuMgrImage(data: image.data).hash
        self.uploaded = false
        self.tested = false
        self.confirmed = false
    }
}

// MARK: - FirmwareUpgradeImage Hashable

extension FirmwareUpgradeImage: Hashable {
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(image)
        hasher.combine(hash)
    }
}

// MARK: - FirmwareUpgradeImage Comparable

extension FirmwareUpgradeImage: Comparable {
    
    public static func < (lhs: FirmwareUpgradeImage, rhs: FirmwareUpgradeImage) -> Bool {
        if lhs.image < rhs.image {
            return true
        } else if lhs.image > rhs.image {
            return false
        }
        return lhs.hashValue < rhs.hashValue
    }
}
