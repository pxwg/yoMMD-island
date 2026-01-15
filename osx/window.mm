#include "window.hpp"
#include <array>
#include <functional>
#include <type_traits>
#include <utility>
#include "../keyboard.hpp"
#include "main.hpp"

// ... (GestureController 类保持不变) ...
class GestureController {
public:
    GestureController();

    void SkipThisGesture();

    // Run "worker" unless this gesture should be skipped.
    template <typename T>
    void Emit(NSEvent *event, std::function<void()> worker, const T& cancelKeys);

public:
    static constexpr std::array<Keycode, 0> WontCancel{};

private:
    bool shouldSkip_;  // TRUE while gesture should be skipped
    std::array<bool, static_cast<std::size_t>(Keycode::Count)> prevKeyState_;
};
// ... (GestureController 实现保持不变) ...

GestureController::GestureController() : shouldSkip_(false) {}

void GestureController::SkipThisGesture() {
    shouldSkip_ = true;
}

template <typename T>
void GestureController::Emit(
    NSEvent *event,
    std::function<void()> worker,
    const T& cancelKeys) {
    static_assert(
        std::is_same_v<typename T::value_type, Keycode>,
        "Contained value type must be Keycode.");
    if (shouldSkip_) {
        if (event.phase == NSEventPhaseBegan)
            // Switched to a new gesture.  Cancel skipping gesture.
            shouldSkip_ = false;
        else
            return;
    }
    if (event.phase == NSEventPhaseBegan) {
        for (const auto key : cancelKeys) {
            prevKeyState_[static_cast<std::size_t>(key)] = Keyboard::IsKeyPressed(key);
        }
    }
    for (const auto key : cancelKeys) {
        if (prevKeyState_[static_cast<std::size_t>(key)] != Keyboard::IsKeyPressed(key)) {
            SkipThisGesture();
            return;
        }
    }
    worker();
}

@implementation Window {
    GestureController gestureController_;
}
// 注意：这里移除了 updateTrackingAreas 等相关代码，只保留原有的 Window 逻辑
- (void)flagsChanged:(NSEvent *)event {
    using KeycodeMap = std::pair<NSEventModifierFlags, Keycode>;
    constexpr std::array<KeycodeMap, static_cast<size_t>(Keycode::Count)> keys({{
        {NSEventModifierFlagShift, Keycode::Shift},
    }});
    for (const auto& [mask, keycode] : keys) {
        if (event.modifierFlags & mask)
            Keyboard::OnKeyDown(keycode);
        else
            Keyboard::OnKeyUp(keycode);
    }
}
- (void)mouseDragged:(NSEvent *)event {
    [getAppMain() getRoutine].OnMouseDragged();
}
- (void)mouseDown:(NSEvent *)event {
    [getAppMain() getRoutine].OnGestureBegin();
}
- (void)mouseUp:(NSEvent *)event {
    [getAppMain() getRoutine].OnGestureEnd();
}
- (void)scrollWheel:(NSEvent *)event {
    constexpr std::array<Keycode, 1> cancelKeys = {Keycode::Shift};
    float delta = event.deltaY * 10.0f;  // TODO: Better factor
    if (event.hasPreciseScrollingDeltas)
        delta = event.scrollingDeltaY;

    if (!event.directionInvertedFromDevice)
        delta = -delta;

    const auto worker = [delta]() { [getAppMain() getRoutine].OnWheelScrolled(delta); };
    gestureController_.Emit(event, worker, cancelKeys);
}
- (void)magnifyWithEvent:(NSEvent *)event {
    auto& routine = [getAppMain() getRoutine];
    GesturePhase phase = GesturePhase::Unknown;
    switch (event.phase) {
    case NSEventPhaseMayBegin:  // fall-through
    case NSEventPhaseBegan:
        routine.OnGestureBegin();
        phase = GesturePhase::Begin;
        break;
    case NSEventPhaseChanged:
        phase = GesturePhase::Ongoing;
        break;
    case NSEventPhaseEnded:  // fall-through
    case NSEventPhaseCancelled:
        routine.OnGestureEnd();
        phase = GesturePhase::End;
        break;
    }
    const auto worker = [&phase, &event]() {
        [getAppMain() getRoutine].OnGestureZoom(phase, event.magnification);
    };
    gestureController_.Emit(event, worker, GestureController::WontCancel);
}
- (void)smartMagnifyWithEvent:(NSEvent *)event {
    Routine& routine = [getAppMain() getRoutine];
    const float defaultScale = routine.GetConfig().defaultScale;
    const float scale = routine.GetModelScale();
    float delta = 0.6f;
    GesturePhase phase = GesturePhase::Begin;
    if (scale != defaultScale) {
        // Reset scaling
        delta = defaultScale - scale;
        phase = GesturePhase::Ongoing;
    }
    routine.OnGestureBegin();
    routine.OnGestureZoom(phase, delta);
    routine.OnGestureEnd();
}
- (BOOL)canBecomeKeyWindow {
    return YES;
}
@end

@implementation WindowDelegate
- (void)windowDidChangeScreen:(NSNotification *)notification {
    NSWindow *window = [notification object];
    const NSScreen *screen = [window screen];
    if (!NSEqualRects(window.frame, screen.visibleFrame)) {
        // 在此原型中，我们不需要强制全屏，因为窗口大小由灵动岛逻辑控制
        // [window setFrame:screen.visibleFrame display:YES animate:NO];
    }
}
- (void)windowWillClose:(NSNotification *)notification {
    [NSApp terminate:self];
}
@end

@implementation View {
    NSTrackingArea *trackingArea_; // [新增]
}

+ (NSMenu *)defaultMenu {
    return [getAppMain() getAppMenu];
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return NO;
}

// [新增] 必须实现 updateTrackingAreas
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (trackingArea_) {
        [self removeTrackingArea:trackingArea_];
    }
    
    // 监控鼠标进入和离开
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | 
                                    NSTrackingActiveAlways | 
                                    NSTrackingInVisibleRect;
                                    
    trackingArea_ = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:options
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:trackingArea_];
}

// [新增] 鼠标进入：展开灵动岛
- (void)mouseEntered:(NSEvent *)event {
    auto& routine = [getAppMain() getRoutine];
    routine.SetNotchState(true); // C++ 层：切换相机目标
    
    // 获取当前 View 所在的 Window
    NSWindow *window = [self window];
    if (!window) return;

    NSRect frame = window.frame;
    float originalTop = frame.origin.y + frame.size.height;
    
    // 目标大小：展开 (400x300)
    frame.size.width = 400;
    frame.size.height = 300;
    
    // 保持顶部位置不变 (向下展开)
    frame.origin.x = ([NSScreen mainScreen].frame.size.width - frame.size.width) / 2;
    frame.origin.y = originalTop - frame.size.height;
    
    [window setFrame:frame display:YES animate:YES];
}

// [新增] 鼠标离开：折叠灵动岛
- (void)mouseExited:(NSEvent *)event {
    auto& routine = [getAppMain() getRoutine];
    routine.SetNotchState(false); // C++ 层：切换相机目标
    
    NSWindow *window = [self window];
    if (!window) return;

    NSRect frame = window.frame;
    float originalTop = frame.origin.y + frame.size.height;
    
    // 目标大小：折叠 (200x44)
    frame.size.width = 200;
    frame.size.height = 44; 
    
    // 保持顶部位置不变
    frame.origin.x = ([NSScreen mainScreen].frame.size.width - frame.size.width) / 2;
    frame.origin.y = originalTop - frame.size.height;
    
    [window setFrame:frame display:YES animate:YES];
}

@end

@implementation ViewDelegate
- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
}
- (void)drawInMTKView:(nonnull MTKView *)view {
    @autoreleasepool {
        auto& routine = [getAppMain() getRoutine];
        routine.Update();
        routine.Draw();
    }
}
@end
