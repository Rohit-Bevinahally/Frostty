// FrosttyNotificationNames.swift
// Frostty
//
// Central definitions for NotificationCenter names and Frostty `userInfo` keys

import Foundation

extension Notification.Name {
    static let ghosttyCloseSurface = Notification.Name("com.frostty.ghostty.closeSurface")
    static let ghosttyNewWindow = Notification.Name("com.frostty.ghostty.newWindow")
    static let ghosttyNewTab = Notification.Name("com.frostty.ghostty.newTab")
    static let ghosttyNewSplit = Notification.Name("com.frostty.ghostty.newSplit")
    static let ghosttyCloseTab = Notification.Name("com.frostty.ghostty.closeTab")
    static let ghosttyCloseWindow = Notification.Name("com.frostty.ghostty.closeWindow")
    static let ghosttySetTitle = Notification.Name("com.frostty.ghostty.setTitle")
    static let ghosttySetPwd = Notification.Name("com.frostty.ghostty.setPwd")
    static let ghosttyCellSizeChange = Notification.Name("com.frostty.ghostty.cellSizeChange")
    static let ghosttyInitialSize = Notification.Name("com.frostty.ghostty.initialSize")
    static let ghosttySizeLimit = Notification.Name("com.frostty.ghostty.sizeLimit")
    static let ghosttyConfigChange = Notification.Name("com.frostty.ghostty.configChange")
    static let ghosttyColorChange = Notification.Name("com.frostty.ghostty.colorChange")
    static let ghosttyToggleFullscreen = Notification.Name("com.frostty.ghostty.toggleFullscreen")
    static let ghosttyRendererHealth = Notification.Name("com.frostty.ghostty.rendererHealth")
    static let ghosttyRingBell = Notification.Name("com.frostty.ghostty.ringBell")
    static let ghosttyShowChildExited = Notification.Name("com.frostty.ghostty.showChildExited")
    static let ghosttyGotoSplit = Notification.Name("com.frostty.ghostty.gotoSplit")
    static let ghosttyResizeSplit = Notification.Name("com.frostty.ghostty.resizeSplit")
    static let ghosttyEqualizeSplits = Notification.Name("com.frostty.ghostty.equalizeSplits")
    static let ghosttyDesktopNotification = Notification.Name("com.frostty.ghostty.desktopNotification")
    static let ghosttyGotoTab = Notification.Name("com.frostty.ghostty.gotoTab")
    static let ghosttyConfirmClipboard = Notification.Name("com.frostty.ghostty.confirmClipboard")
    static let frosttyRenameTab = Notification.Name("com.frostty.renameTab")
    static let frosttyWillBeginEditing = Notification.Name("com.frostty.willBeginEditing")
    static let frosttyDidEndEditing = Notification.Name("com.frostty.didEndEditing")
    static let frosttyShowNewWorkspaceSheet = Notification.Name("com.frostty.showNewWorkspaceSheet")
    static let frosttySurfaceDidFocus = Notification.Name("com.frostty.surfaceDidFocus")
    static let frosttyBrowserPaneDidFocus = Notification.Name("frosttyBrowserPaneDidFocus")
    static let frosttyPaneDragEndedNoTarget = Notification.Name("frosttyPaneDragEndedNoTarget")
    static let frosttyFocusBrowserAddressBar = Notification.Name("com.frostty.focusBrowserAddressBar")
    static let frosttyPaneRestructureCompleted = Notification.Name("com.frostty.paneRestructureCompleted")
    static let ghosttyStartSearch = Notification.Name("com.frostty.ghostty.startSearch")
    static let ghosttyEndSearch = Notification.Name("com.frostty.ghostty.endSearch")
    static let ghosttySearchTotal = Notification.Name("com.frostty.ghostty.searchTotal")
    static let ghosttySearchSelected = Notification.Name("com.frostty.ghostty.searchSelected")
}

/// String keys for `userInfo` on Frostty notifications
enum FrosttyUserInfoKey {
    static let paneDragEndedNoTargetPoint = "endedAtPoint"
    static let paneRestructureSourceTabID = "sourceTabID"
    static let paneRestructureDestinationTabID = "destinationTabID"
    static let paneRestructurePaneID = "paneID"
}
