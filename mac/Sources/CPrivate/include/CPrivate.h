#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// CoreGraphics' virtual display SPI (same interface Chromium's test harness uses).
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain) NSString *name;
@property unsigned int maxPixelsWide, maxPixelsHigh, productID, vendorID, serialNum;
@property CGSize sizeInMillimeters;
@property CGPoint whitePoint, redPrimary, greenPrimary, bluePrimary;
@property (copy) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)q;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned)w height:(unsigned)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (retain) NSArray<CGVirtualDisplayMode *> *modes;
@property unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property (readonly) CGDirectDisplayID displayID;
@end

typedef NS_ENUM(int, MTGestureKind) { MTGestureMagnify = 8, MTGestureRotate = 5 };
// phase: 1 began, 2 changed, 4 ended, 8 cancelled
void MTPostGesture(CGPoint location, MTGestureKind kind, double value, int phase);
// The same events, handed to `sink` instead of the session.
void MTEachGestureEvent(CGPoint location, MTGestureKind kind, double value, int phase, void (^sink)(CGEventRef));
