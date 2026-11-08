#import "CPrivate.h"
// Trackpad gesture CGEvents have no public constructor. These field numbers are the
// ones WindowServer itself emits for NSEventTypeGesture (29).
enum { kFieldSubtype = 110, kFieldMagnify = 113, kFieldRotate = 114, kFieldPhase = 132 };
enum { kSubtypeBegin = 61, kSubtypeEnd = 62 };

static void post(CGPoint p, int subtype, int field, double value, int phase) {
    CGEventRef e = CGEventCreate(NULL);
    CGEventSetType(e, (CGEventType)29);
    CGEventSetLocation(e, p);
    CGEventSetIntegerValueField(e, kFieldSubtype, subtype);
    if (field) CGEventSetDoubleValueField(e, field, value);
    if (phase) CGEventSetIntegerValueField(e, kFieldPhase, phase);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}
void MTPostGesture(CGPoint p, MTGestureKind kind, double value, int phase) {
    int field = kind == MTGestureMagnify ? kFieldMagnify : kFieldRotate;
    if (phase == 1) post(p, kSubtypeBegin, 0, 0, 0);
    post(p, kind, field, value, phase);
    if (phase == 4 || phase == 8) post(p, kSubtypeEnd, 0, 0, 0);
}
