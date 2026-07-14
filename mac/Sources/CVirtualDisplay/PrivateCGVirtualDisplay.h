// Declarations for Apple's PRIVATE CoreGraphics virtual-display classes.
// These are not part of the public SDK; we declare the interfaces we use so
// the compiler is happy, and instantiate them at runtime via NSClassFromString
// so the app degrades gracefully if Apple ever removes them.
//
// This header is intentionally NOT in the public `include/` directory, so it
// is never exposed to the Swift side.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) uint32_t width;
@property(readonly, nonatomic) uint32_t height;
@property(readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(strong, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) uint32_t hiDPI;
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(strong, nonatomic) dispatch_queue_t queue;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t serialNum;
@property(copy, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(copy, nonatomic) void (^terminationHandler)(void);
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) uint32_t displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
