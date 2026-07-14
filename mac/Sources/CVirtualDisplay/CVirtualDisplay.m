#import "CVirtualDisplay.h"
#import "PrivateCGVirtualDisplay.h"

@interface TLVirtualDisplay ()
// Held strongly: releasing this object tears down the virtual display.
@property (nonatomic, strong) id display;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation TLVirtualDisplay

- (nullable instancetype)initWithWidth:(uint32_t)width
                                height:(uint32_t)height
                                 hiDPI:(BOOL)hiDPI
                                  name:(NSString *)name {
    self = [super init];
    if (!self) return nil;

    Class descClass     = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass     = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass  = NSClassFromString(@"CGVirtualDisplay");
    if (!descClass || !settingsClass || !modeClass || !displayClass) {
        NSLog(@"[TessyLink] CGVirtualDisplay private classes unavailable on this macOS version.");
        return nil;
    }

    _width  = width;
    _height = height;
    _queue  = dispatch_queue_create("com.tessylink.virtualdisplay", DISPATCH_QUEUE_SERIAL);

    CGVirtualDisplayDescriptor *descriptor = [[descClass alloc] init];
    descriptor.queue    = _queue;
    descriptor.name     = name;
    descriptor.vendorID = 0x1AF5;   // arbitrary but stable
    descriptor.productID = 0x0100;
    descriptor.serialNum = 0x0001;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    // Assume ~110 ppi to derive a plausible physical size (mm).
    descriptor.sizeInMillimeters = CGSizeMake(width  / 110.0 * 25.4,
                                              height / 110.0 * 25.4);
    descriptor.redPrimary   = CGPointMake(0.640, 0.330);
    descriptor.greenPrimary = CGPointMake(0.300, 0.600);
    descriptor.bluePrimary  = CGPointMake(0.150, 0.060);
    descriptor.whitePoint   = CGPointMake(0.3127, 0.3290);
    descriptor.terminationHandler = ^{ /* display went away */ };

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) {
        NSLog(@"[TessyLink] Failed to create CGVirtualDisplay.");
        return nil;
    }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;

    NSMutableArray *modes = [NSMutableArray array];
    [modes addObject:[[modeClass alloc] initWithWidth:width height:height refreshRate:60.0]];
    if (hiDPI && width >= 2 && height >= 2) {
        // Offer a half-resolution point mode so the OS presents a crisp @2x desktop.
        [modes addObject:[[modeClass alloc] initWithWidth:width / 2 height:height / 2 refreshRate:60.0]];
    }
    settings.modes = modes;

    if (![display applySettings:settings]) {
        NSLog(@"[TessyLink] applySettings failed.");
        return nil;
    }

    _display   = display;
    _displayID = display.displayID;
    NSLog(@"[TessyLink] Virtual display created: id=%u %ux%u", _displayID, width, height);
    return self;
}

- (void)dealloc {
    // Dropping the strong reference tears the display down.
    _display = nil;
}

@end
