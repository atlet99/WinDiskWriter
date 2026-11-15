//
//  MiddleAlignedCell.h
//  WinDiskWriter GUI
//
//  Created by Macintosh on 03.12.2023.
//  Copyright © 2023 TechUnRestricted. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Fix for TechUnRestricted/windiskwriter#74: AppKit (macOS Tahoe 26.6+) calls the
// private _visualProviderIfExists selector, which a bare NSCell lacks — crash on
// launch. NSTextFieldCell provides the expected implementation.
@interface MiddleAlignedCell : NSTextFieldCell

@end

NS_ASSUME_NONNULL_END
