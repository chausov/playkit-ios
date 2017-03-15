//
//  AVPlayerEngine+Observation.swift
//  Pods
//
//  Created by Gal Orlanczyk on 07/03/2017.
//
//

import Foundation
import AVFoundation
import CoreMedia

extension AVPlayerEngine {
    
    // An array of key paths for the properties we want to observe.
    private var observedKeyPaths: [String] {
        return [
            #keyPath(rate),
            #keyPath(currentItem.status),
            #keyPath(currentItem),
            #keyPath(currentItem.playbackLikelyToKeepUp),
            #keyPath(currentItem.playbackBufferEmpty),
            #keyPath(currentItem.duration)
        ]
    }
    
    // - Observers
    func addObservers() {
        PKLog.trace("addObservers")
        
        self.isObserved = true
        // Register observers for the properties we want to display.
        for keyPath in observedKeyPaths {
            addObserver(self, forKeyPath: keyPath, options: [.new, .initial], context: &observerContext)
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.playerFailed(notification:)), name: .AVPlayerItemFailedToPlayToEndTime, object: self.currentItem)
        NotificationCenter.default.addObserver(self, selector: #selector(self.playerPlayedToEnd(notification:)), name: .AVPlayerItemDidPlayToEndTime, object: self.currentItem)
        NotificationCenter.default.addObserver(self, selector: #selector(self.onAccessLogEntryNotification), name: .AVPlayerItemNewAccessLogEntry, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.onErrorLogEntryNotification), name: .AVPlayerItemNewErrorLogEntry, object: nil)
    }
    
    func removeObservers() {
        if !self.isObserved {
            return
        }
        
        PKLog.trace("removeObservers")
        
        // Un-register observers
        for keyPath in observedKeyPaths {
            removeObserver(self, forKeyPath: keyPath, context: &observerContext)
        }
        
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemNewAccessLogEntry, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemNewErrorLogEntry, object: nil)
    }
    
    func onAccessLogEntryNotification(notification: Notification) {
        if let item = notification.object as? AVPlayerItem, let accessLog = item.accessLog(), let lastEvent = accessLog.events.last {
            if #available(iOS 10.0, *) {
                PKLog.debug("event log:\n event log: averageAudioBitrate - \(lastEvent.averageAudioBitrate)\n event log: averageVideoBitrate - \(lastEvent.averageVideoBitrate)\n event log: indicatedAverageBitrate - \(lastEvent.indicatedAverageBitrate)\n event log: indicatedBitrate - \(lastEvent.indicatedBitrate)\n event log: observedBitrate - \(lastEvent.observedBitrate)\n event log: observedMaxBitrate - \(lastEvent.observedMaxBitrate)\n event log: observedMinBitrate - \(lastEvent.observedMinBitrate)\n event log: switchBitrate - \(lastEvent.switchBitrate)")
            }
            
            if lastEvent.indicatedBitrate != self.lastBitrate {
                self.lastBitrate = lastEvent.indicatedBitrate
                PKLog.trace("currentBitrate:: \(self.lastBitrate)")
                self.post(event: PlayerEvent.PlaybackParamsUpdated(currentBitrate: self.lastBitrate))
            }
        }
    }
    
    func onErrorLogEntryNotification(notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem, let errorLog = playerItem.errorLog(), let lastEvent = errorLog.events.last else { return }
        PKLog.error("error description: \(lastEvent.errorComment), error domain: \(lastEvent.errorDomain), error code: \(lastEvent.errorStatusCode)")
        self.post(event: PlayerEvent.Error(error: PlayerError.playerItemErrorLogEvent(errorLogEvent: lastEvent)))
    }
    
    public func playerFailed(notification: NSNotification) {
        let newState = PlayerState.error
        self.postStateChange(newState: newState, oldState: self.currentState)
        self.currentState = newState
        
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError {
            self.post(event: PlayerEvent.Error(error: PlayerError.failedToPlayToEndTime(rootError: error)))
        } else {
            self.post(event: PlayerEvent.Error())
        }
    }
    
    public func playerPlayedToEnd(notification: NSNotification) {
        let newState = PlayerState.idle
        self.postStateChange(newState: newState, oldState: self.currentState)
        self.currentState = newState
        self.isPlayedToEndTime = true
        self.post(event: PlayerEvent.Ended())
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        PKLog.debug("observeValue:: onEvent/onState")
        
        guard context == &observerContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        
        guard let keyPath = keyPath else {
            return
        }
        
        PKLog.debug("keyPath:: \(keyPath)")
        
        switch keyPath {
        case #keyPath(currentItem.playbackLikelyToKeepUp):
            self.handleLikelyToKeepUp()
        case #keyPath(currentItem.playbackBufferEmpty):
            self.handleBufferEmptyChange()
        case #keyPath(currentItem.duration):
            if let currentItem = self.currentItem {
                self.post(event: PlayerEvent.DurationChanged(duration: CMTimeGetSeconds(currentItem.duration)))
            }
        case #keyPath(rate):
            self.handleRate()
        case #keyPath(currentItem.status):
            self.handleStatusChange()
        case #keyPath(currentItem):
            self.handleItemChange()
        default:
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func handleLikelyToKeepUp() {
        if self.currentItem != nil {
            let newState = PlayerState.ready
            self.postStateChange(newState: newState, oldState: self.currentState)
            self.currentState = newState
        }
    }
    
    private func handleBufferEmptyChange() {
        if self.currentItem != nil {
            let newState = PlayerState.buffering
            self.postStateChange(newState: newState, oldState: self.currentState)
            self.currentState = newState
        }
    }
    
    /// Handles change in player rate
    ///
    /// - Returns: The event to post, rate <= 0 means pause event.
    private func handleRate() {
        if rate > 0 {
            self.startOrResumeNonObservablePropertiesUpdateTimer()
        } else {
            self.nonObservablePropertiesUpdateTimer?.invalidate()
            // we don't want pause events to be sent when current item reached end.
            if !isPlayedToEndTime {
                self.post(event: PlayerEvent.Pause())
            }
        }
    }
    
    private func handleStatusChange() {
        if currentItem?.status == .readyToPlay {
            let newState = PlayerState.ready
            self.post(event: PlayerEvent.LoadedMetadata())
            
            if self.startPosition > 0 {
                self.currentPosition = self.startPosition
                self.startPosition = 0
            }
            
            self.tracksManager.handleTracks(item: self.currentItem, block: { (tracks: PKTracks) in
                self.post(event: PlayerEvent.TracksAvailable(tracks: tracks))
            })
            
            self.postStateChange(newState: newState, oldState: self.currentState)
            self.currentState = newState
            
            self.post(event: PlayerEvent.CanPlay())
        } else if currentItem?.status == .failed {
            let newState = PlayerState.error
            self.postStateChange(newState: newState, oldState: self.currentState)
            self.currentState = newState
        }
    }
    
    private func handleItemChange() {
        let newState = PlayerState.idle
        self.postStateChange(newState: newState, oldState: self.currentState)
        self.currentState = newState
        // in case item changed reset player reached end time indicator
        isPlayedToEndTime = false
    }
}