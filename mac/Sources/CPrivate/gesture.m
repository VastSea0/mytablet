#import "CPrivate.h"
// Trackpad gesture CGEvents have no public constructor. These field numbers are the
// ones WindowServer itself emits for NSEventTypeGesture (29).
enum { kFieldSubtype = 110, kFieldMagnify = 113, kFieldRotate = 114, kFieldPhase = 132 };
enum { kSubtypeBegin = 61, kSubtypeEnd = 62 };

static void emit(CGPoint p, int subtype, int field, double value, int phase, void (^sink)(CGEventRef)) {
    CGEventRef e = CGEventCreate(NULL);
    CGEventSetType(e, (CGEventType)29);
    CGEventSetLocation(e, p);
    CGEventSetIntegerValueField(e, kFieldSubtype, subtype);
    if (field) CGEventSetDoubleValueField(e, field, value);
    if (phase) CGEventSetIntegerValueField(e, kFieldPhase, phase);
    sink(e);
    CFRelease(e);
}
void MTEachGestureEvent(CGPoint p, MTGestureKind kind, double value, int phase, void (^sink)(CGEventRef)) {
    int field = kind == MTGestureMagnify ? kFieldMagnify : kFieldRotate;
    if (phase == 1) emit(p, kSubtypeBegin, 0, 0, 0, sink);
    emit(p, kind, field, value, phase, sink);
    if (phase == 4 || phase == 8) emit(p, kSubtypeEnd, 0, 0, 0, sink);
}
void MTPostGesture(CGPoint p, MTGestureKind kind, double value, int phase) {
    MTEachGestureEvent(p, kind, value, phase, ^(CGEventRef e) { CGEventPost(kCGHIDEventTap, e); });
}
