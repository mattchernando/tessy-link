#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A thin, ARC-friendly wrapper around Apple's private CGVirtualDisplay
/// CoreGraphics classes. Creating an instance registers a new virtual
/// display with the window server; releasing it (deallocating) tears the
/// display down again.
@interface TLVirtualDisplay : NSObject

/// The CGDirectDisplayID the system assigned to this virtual display.
@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;

/// Returns nil if the private APIs are unavailable on this macOS version
/// or the display could not be created.
- (nullable instancetype)initWithWidth:(uint32_t)width
                                height:(uint32_t)height
                                 hiDPI:(BOOL)hiDPI
                                  name:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
